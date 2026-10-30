import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/json.dart';
import '../../../core/money.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/subcontract_repository.dart';
import '../models/subcontract_models.dart';
import '../../../widgets/busy.dart';

/// Creates an RA bill (from the work order's template) or edits a draft.
class RaBillFormScreen extends ConsumerStatefulWidget {
  const RaBillFormScreen({super.key, this.billId, this.initialWorkOrderId});

  final String? billId;
  final String? initialWorkOrderId;

  @override
  ConsumerState<RaBillFormScreen> createState() => _RaBillFormScreenState();
}

class _RaBillFormScreenState extends ConsumerState<RaBillFormScreen> {
  String? _workOrderId;

  @override
  void initState() {
    super.initState();
    _workOrderId = widget.initialWorkOrderId;
  }

  @override
  Widget build(BuildContext context) {
    final billId = widget.billId;
    return CGate(
      anyOf: const [CPerm.subcontractsManage],
      child: billId != null
          ? AsyncValueView(
              value: ref.watch(raBillProvider(billId)),
              onRetry: () => ref.invalidate(raBillProvider(billId)),
              data: (bill) =>
                  _WithWorkOrder(workOrderId: bill.workOrderId, original: bill),
            )
          : _workOrderId == null
          ? _Picker(onPicked: (id) => setState(() => _workOrderId = id))
          : _WithWorkOrder(workOrderId: _workOrderId!),
    );
  }
}

class _Picker extends ConsumerWidget {
  const _Picker({required this.onPicked});

  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const PageHeader(title: 'New RA bill'),
      Expanded(
        child: AsyncValueView(
          value: ref.watch(activeWorkOrdersProvider),
          onRetry: () => ref.invalidate(activeWorkOrdersProvider),
          data: (orders) => CPage(
            maxWidth: 700,
            children: [
              SectionCard(
                title: 'Choose the work order',
                child: orders.isEmpty
                    ? const Text('There are no active work orders.')
                    : Column(
                        children: [
                          for (final w in orders)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              enabled: !w.hasFinalBill,
                              title: Text('${w.number} · ${w.title}'),
                              subtitle: Text(
                                '${w.contractorName} · ${w.projectName}',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => onPicked(w.id),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class _WithWorkOrder extends ConsumerWidget {
  const _WithWorkOrder({required this.workOrderId, this.original});

  final String workOrderId;
  final RaBill? original;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wo = ref.watch(workOrderProvider(workOrderId));
    final template = original == null
        ? ref.watch(raBillTemplateProvider(workOrderId))
        : null;
    final lines = original?.lines;
    return AsyncValueView(
      value: wo,
      onRetry: () => ref.invalidate(workOrderProvider(workOrderId)),
      data: (order) {
        if (original != null) {
          return _RaForm(
            workOrder: order,
            lines: lines ?? const [],
            original: original,
          );
        }
        return AsyncValueView(
          value: template!,
          onRetry: () => ref.invalidate(raBillTemplateProvider(workOrderId)),
          data: (t) => _RaForm(workOrder: order, lines: t.lines ?? const []),
        );
      },
    );
  }
}

class _RaForm extends ConsumerStatefulWidget {
  const _RaForm({required this.workOrder, required this.lines, this.original});

  final WorkOrder workOrder;
  final List<RaBillLine> lines;
  final RaBill? original;

  @override
  ConsumerState<_RaForm> createState() => _RaFormState();
}

class _RaFormState extends ConsumerState<_RaForm> with DirtyTracking<_RaForm> {
  final _formKey = GlobalKey<FormState>();
  late final List<TextEditingController> _cum = [
    for (final l in widget.lines)
      TextEditingController(text: formatPlain(l.cumQty)),
  ];
  late final _retention = TextEditingController();
  late final _advance = TextEditingController();
  late final _tds = TextEditingController();
  late final _cess = TextEditingController();
  late final _other = TextEditingController();
  late final _otherNote = TextEditingController(
    text: widget.original?.otherDeductionNote,
  );
  late final _notes = TextEditingController(text: widget.original?.notes);
  late DateTime _date = parseApiDate(widget.original?.date) ?? today();
  late bool _final = widget.original?.isFinal ?? false;
  bool _submit = false;
  bool _busy = false;

  bool get _editing => widget.original != null;
  late final RaTerms _terms = RaTerms.of(widget.workOrder);

  @override
  void initState() {
    super.initState();
    final o = widget.original;
    if (o != null) {
      // Prefill an override only where the stored value is not the default.
      final d = RaBillMath.compute(_measures(), _terms);
      void fill(TextEditingController c, double stored, double def) {
        if ((stored - def).abs() > 0.004) c.text = formatPlain(stored);
      }

      fill(_retention, o.retention, d.retention);
      fill(_advance, o.advanceRecovery, d.advanceRecovery);
      fill(_tds, o.tds, d.tds);
      fill(_cess, o.cess, d.cess);
      fill(_other, o.otherDeduction, 0);
    }
  }

  @override
  void dispose() {
    for (final c in [
      ..._cum,
      _retention,
      _advance,
      _tds,
      _cess,
      _other,
      _otherNote,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  List<RaMeasure> _measures() => [
    for (final (i, l) in widget.lines.indexed)
      RaMeasure(
        rate: l.rate,
        prevQty: l.prevQty,
        cumQty: parseNumber(_cum[i].text) ?? l.prevQty,
      ),
  ];

  Map<String, double> _overrides() => {
    for (final (key, c) in [
      ('retention', _retention),
      ('advanceRecovery', _advance),
      ('tds', _tds),
      ('cess', _cess),
      ('otherDeduction', _other),
    ])
      if (parseNumber(c.text) != null) key: parseNumber(c.text)!,
  };

  RaBillMath get _math =>
      RaBillMath.compute(_measures(), _terms, overrides: _overrides());

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final math = _math;
    if (math.isNegative) {
      markSaved();
      showInfoSnackBar(
        context,
        'Net payable is negative. Reduce the deductions.',
      );
      return;
    }
    final o = _overrides();
    final body = <String, dynamic>{
      if (!_editing) 'workOrderId': widget.workOrder.id,
      'date': apiDate(_date),
      'isFinal': _final,
      'notes': trimmedOrNull(_notes.text),
      'lines': [
        for (final (i, l) in widget.lines.indexed)
          {
            'workOrderLineId': l.workOrderLineId,
            'cumQty': parseNumber(_cum[i].text) ?? l.prevQty,
          },
      ],
      ...o,
      if (o.containsKey('otherDeduction') && o['otherDeduction']! > 0)
        'otherDeductionNote': trimmedOrNull(_otherNote.text),
      if (!_editing && _submit) 'submit': true,
    };
    setState(() => _busy = true);
    try {
      final repo = ref.read(subcontractRepositoryProvider);
      final Json _ = body;
      final bill = _editing
          ? await repo.updateRaBill(widget.original!.id, body)
          : await repo.createRaBill(body);
      ref.bumpC(const [CKind.raBills]);
      ref.invalidate(raBillProvider(bill.id));
      if (!mounted) return;
      showSuccess(context, '${bill.number} saved');
      context.go('/ra-bills/${bill.id}');
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _deduction(
    TextEditingController c,
    String label,
    double def, {
    double? max,
  }) => TextFormField(
    controller: c,
    keyboardType: decimalKeyboard,
    inputFormatters: [decimalInput()],
    onChanged: (_) => setState(() {}),
    decoration: InputDecoration(
      labelText: label,
      prefixText: '₹ ',
      helperText: 'Default ${formatMoney(def)}',
    ),
    validator: (v) {
      final error = optionalNumber(v, min: 0);
      if (error != null) return error;
      final n = parseNumber(v ?? '');
      if (n != null && max != null && n > max + 0.004) {
        return 'At most ${formatMoney(max)}';
      }
      return null;
    },
  );

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final wo = widget.workOrder;
    final math = _math;
    final defaults = RaBillMath.compute(_measures(), _terms);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: _editing ? 'Edit ${widget.original!.number}' : 'New RA bill',
          subtitle: '${wo.number} · ${wo.contractorName}',
        ),
        Expanded(
          child: BottomBarLayout(
            bar: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(
                  'Net payable ${formatMoney(math.netPayable)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: math.isNegative ? theme.colorScheme.error : null,
                  ),
                ),
                OutlinedButton(
                  style: bigOutlinedButton,
                  onPressed: _busy
                      ? null
                      : () => context.go(
                          _editing
                              ? '/ra-bills/${widget.original!.id}'
                              : '/work-orders/${wo.id}',
                        ),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: bigButton,
                  onPressed: _busy ? null : _save,
                  child: Text(_editing ? 'Save changes' : 'Save RA bill'),
                ),
              ],
            ),
            child: Form(
              key: _formKey,
              onChanged: markDirty,
              child: CPage(
                maxWidth: 1000,
                children: [
                  SectionCard(
                    title: 'Bill',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FormRow(
                          children: [
                            DateField(
                              label: 'Bill date',
                              value: _date,
                              onChanged: (v) => setState(() => _date = v),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Final bill'),
                              value: _final,
                              onChanged: (v) => setState(() => _final = v),
                            ),
                          ],
                        ),
                        TextFormField(
                          controller: _notes,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'Notes (optional)',
                          ),
                        ),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: 'Measurements',
                    child: Column(
                      children: [
                        for (final (i, l) in widget.lines.indexed) ...[
                          if (i > 0) const Divider(height: 24),
                          _MeasureRow(
                            line: l,
                            controller: _cum[i],
                            onChanged: () => setState(() {}),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SectionCard(
                    title: 'Deductions',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Leave a field blank to use the work order default.',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        FormRow(
                          breakpoint: 640,
                          children: [
                            _deduction(
                              _retention,
                              'Retention',
                              defaults.retention,
                              max: math.gross,
                            ),
                            _deduction(
                              _advance,
                              'Advance recovery',
                              defaults.advanceRecovery,
                              max: wo.advance.balance < math.gross
                                  ? wo.advance.balance
                                  : math.gross,
                            ),
                            _deduction(
                              _tds,
                              'TDS',
                              defaults.tds,
                              max: math.gross,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        FormRow(
                          breakpoint: 640,
                          children: [
                            _deduction(
                              _cess,
                              'BOCW cess',
                              defaults.cess,
                              max: math.gross,
                            ),
                            _deduction(
                              _other,
                              'Other deduction',
                              0,
                              max: math.gross,
                            ),
                            TextFormField(
                              controller: _otherNote,
                              decoration: const InputDecoration(
                                labelText: 'Other deduction note',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  _Preview(math: math, terms: _terms),
                  if (!_editing)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('Submit for approval after saving'),
                      value: _submit,
                      onChanged: (v) => setState(() => _submit = v ?? false),
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

class _MeasureRow extends StatelessWidget {
  const _MeasureRow({
    required this.line,
    required this.controller,
    required this.onChanged,
  });

  final RaBillLine line;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final cum = parseNumber(controller.text) ?? line.prevQty;
    final measure = RaMeasure(
      rate: line.rate,
      prevQty: line.prevQty,
      cumQty: cum,
    );
    final field = TextFormField(
      controller: controller,
      keyboardType: decimalKeyboard,
      inputFormatters: [decimalInput()],
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(
        labelText: 'Cumulative qty (${line.unit})',
        helperText:
            'Between ${formatQty(line.prevQty)} and '
            '${formatQty(line.qty)}',
        helperMaxLines: 2,
      ),
      validator: (v) {
        final n = parseNumber(v ?? '');
        if (n == null) return 'Enter the cumulative quantity';
        if (n < line.prevQty - 1e-9) {
          return 'At least ${formatQty(line.prevQty)}';
        }
        if (n > line.qty + 1e-9) return 'At most ${formatQty(line.qty)}';
        return null;
      },
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line.description, style: Theme.of(context).textTheme.titleSmall),
        Text(
          'Rate ${formatMoney(line.rate)} · previous ${formatQty(line.prevQty)}'
          ' · this bill ${formatQty(measure.thisQty)} ${line.unit}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Text(
          'Amount ${formatMoney(measure.amount)}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, c) => c.maxWidth >= 640
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: info),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: field),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [info, const SizedBox(height: 8), field],
            ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.math, required this.terms});

  final RaBillMath math;
  final RaTerms terms;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(
      String label,
      double amount, {
      bool bold = false,
      bool minus = false,
    }) {
      final style = bold ? const TextStyle(fontWeight: FontWeight.w700) : null;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(child: Text(label, style: style)),
            Text('${minus ? '− ' : ''}${formatMoney(amount)}', style: style),
          ],
        ),
      );
    }

    return SectionCard(
      title: 'Net payable preview',
      child: Column(
        children: [
          row('Gross work value', math.gross),
          row('GST (${formatPlain(terms.gstPct)}%)', math.gst),
          row('Retention', math.retention, minus: true),
          row('Advance recovery', math.advanceRecovery, minus: true),
          row('TDS', math.tds, minus: true),
          row('BOCW cess', math.cess, minus: true),
          row('Other deduction', math.otherDeduction, minus: true),
          const Divider(),
          row('Net payable', math.netPayable, bold: true),
          if (math.isNegative)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Net payable is negative, so the server will reject this bill.',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
