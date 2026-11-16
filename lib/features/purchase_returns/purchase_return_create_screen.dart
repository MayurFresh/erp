import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/busy.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../documents/document_models.dart';
import '../documents/document_widgets.dart';
import '../documents/line_editor.dart';
import '../purchases/purchase_model.dart';
import '../purchases/purchases_repository.dart';
import 'purchase_return_model.dart';
import 'purchase_returns_repository.dart';

/// Return goods to a vendor, or claim a price reduction, against one bill.
class PurchaseReturnCreateScreen extends ConsumerStatefulWidget {
  const PurchaseReturnCreateScreen({super.key, this.initialPurchaseId});

  final String? initialPurchaseId;

  @override
  ConsumerState<PurchaseReturnCreateScreen> createState() =>
      _PurchaseReturnCreateScreenState();
}

class _PurchaseReturnCreateScreenState
    extends ConsumerState<PurchaseReturnCreateScreen>
    with DirtyTracking<PurchaseReturnCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  final Map<String, TextEditingController> _input = {};
  Purchase? _bill;
  Object? _billError;
  bool _loading = false;
  bool _goods = true;
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  bool _saving = false;
  Object? _saveError;

  @override
  void initState() {
    super.initState();
    final id = widget.initialPurchaseId;
    if (id != null) _loadBill(id);
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final c in _input.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Lines with something left to give back in the chosen mode.
  List<PurchaseLine> get _open => (_bill?.lines ?? const <PurchaseLine>[])
      .where((l) => l.id != null && _left(l) > 0)
      .toList();

  double _left(PurchaseLine l) => _goods
      ? (l.qty - l.returnedQty).clamp(0, double.infinity)
      : (l.taxableValue - l.returnedTaxable).clamp(0, double.infinity);

  Future<void> _loadBill(String id) async {
    setState(() {
      _loading = true;
      _billError = null;
    });
    try {
      final bill = await ref.read(purchasesRepositoryProvider).get(id);
      if (!mounted) return;
      setState(() {
        _bill = bill;
        _loading = false;
        _resetInputs();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _billError = e;
        _loading = false;
      });
    }
  }

  void _resetInputs() {
    for (final c in _input.values) {
      c.dispose();
    }
    _input.clear();
    for (final l in _open) {
      _input[l.id!] = TextEditingController();
    }
  }

  Future<void> _pickBill() async {
    final repo = ref.read(purchasesRepositoryProvider);
    final picked = await showSearchPicker<Purchase>(
      context: context,
      title: 'Choose a purchase bill',
      hintText: 'Search number or vendor',
      emptyMessage: 'No posted bills match.',
      search: (q) async =>
          (await repo.list(q: q, status: DocStatus.posted, limit: 50)).data,
      titleBuilder: (context, b) => Text(b.number ?? '—'),
      subtitleBuilder: (context, b) =>
          Text('${b.partyName} · ${formatDate(b.billDate)}'),
      trailingBuilder: (context, b) => Text(formatMoney(b.total)),
    );
    if (picked?.id != null) _loadBill(picked!.id!);
  }

  Map<String, double> get _values => {
    for (final MapEntry(:key, value: c) in _input.entries)
      if ((parseNumber(c.text) ?? 0) > 0) key: parseNumber(c.text)!,
  };

  /// Taxable value and tax worked out here for display; the server's figures are final.
  ({double taxable, double tax}) get _estimate {
    var taxable = 0.0;
    var tax = 0.0;
    for (final l in _open) {
      final v = _values[l.id] ?? 0;
      if (v <= 0) continue;
      final t = _goods && l.qty > 0 ? l.taxableValue * v / l.qty : v;
      taxable += t;
      tax += t * l.gstRate / 100;
    }
    return (taxable: taxable, tax: tax);
  }

  void _setAll() {
    for (final l in _open) {
      _input[l.id!]!.text = formatPlain(_left(l));
    }
    setState(() {});
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saveError = null);
    final valid = validateAndReveal(_formKey);
    if (_bill == null) return;
    if (_values.isEmpty) {
      showInfoSnackBar(
        context,
        _goods
            ? 'Enter the quantity returned on a line.'
            : 'Enter the amount on a line.',
      );
      return;
    }
    if (!valid) return;
    setState(() => _saving = true);
    try {
      final note = await ref
          .read(purchaseReturnsRepositoryProvider)
          .create(
            PurchaseReturnDraft(
              purchaseId: _bill!.id!,
              kind: _goods ? 'goods' : 'price',
              reason: _reason.text.trim(),
              returnDate: apiDate(_date),
              lines: _values,
            ),
          );
      ref.bump(const [
        DataKind.purchaseReturns,
        DataKind.purchases,
        DataKind.stock,
        DataKind.parties,
      ]);
      markSaved();
      if (!mounted) return;
      showInfoSnackBar(context, 'Debit note ${note.number} saved');
      context.go('/purchase-returns/${note.id}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveError = e);
      showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final bill = _bill;
    final est = _estimate;
    final details = SectionCard(
      title: 'Details',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormRow(
            children: [
              PickerField(
                label: 'Purchase bill',
                value: bill == null ? null : '${bill.number} · ${bill.partyName}',
                onTap: _pickBill,
                enabled: widget.initialPurchaseId == null,
                validator: () => bill == null ? 'Choose a bill' : null,
              ),
              PickerField(
                label: 'Date',
                value: formatDate(_date),
                icon: Icons.calendar_today_outlined,
                onTap: () async {
                  final p = await pickDocDate(context, _date);
                  if (p != null && mounted) setState(() => _date = p);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Return goods')),
              ButtonSegment(value: false, label: Text('Price reduction')),
            ],
            selected: {_goods},
            onSelectionChanged: (s) => setState(() {
              _goods = s.first;
              _resetInputs();
            }),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _reason,
            decoration: const InputDecoration(
              labelText: 'Reason',
              hintText: 'e.g. Damaged on arrival',
            ),
            validator: (v) => requiredField(v, 'Reason'),
          ),
        ],
      ),
    );
    final lines = SectionCard(
      title: _goods ? 'Items returned' : 'Price reduction per line',
      child: _linesBody(),
    );
    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: DocFormLayout(
        bottomBar: DocSaveBar(
          busy: _saving,
          onPressed: _save,
          label: 'Save debit note',
        ),
        title: 'New debit note',
        main: [details, lines],
        summary: SectionCard(
          title: 'Summary',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AmountRow('Taxable value (estimate)', est.taxable),
              AmountRow('GST (estimate)', est.tax),
              AmountRow(
                'Total (estimate)',
                est.taxable + est.tax,
                emphasize: true,
              ),
              const SizedBox(height: 8),
              Text(
                'The exact figures, rounding and any TDS come back when you save.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 12),
                ApiErrorBox(error: _saveError!, subject: 'the debit note'),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _linesBody() {
    if (_loading) return const LinearProgressIndicator();
    if (_billError != null) {
      return ErrorView(
        error: _billError!,
        onRetry: widget.initialPurchaseId == null
            ? null
            : () => _loadBill(widget.initialPurchaseId!),
      );
    }
    final bill = _bill;
    if (bill == null) return const Text('Choose a bill first.');
    if (bill.isCancelled) {
      return const Text('This bill is cancelled; nothing can be returned.');
    }
    final open = _open;
    if (open.isEmpty) {
      return Text(
        _goods
            ? 'Everything on this bill has been returned.'
            : 'Nothing is left to reduce on this bill.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _setAll,
            icon: const Icon(Icons.select_all),
            label: Text(_goods ? 'Return everything' : 'Use the full amounts'),
          ),
        ),
        const SizedBox(height: 8),
        for (final l in open)
          _Line(
            key: ValueKey('${l.id}-$_goods'),
            line: l,
            goods: _goods,
            left: _left(l),
            controller: _input[l.id]!,
            onChanged: () => setState(() {}),
          ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    super.key,
    required this.line,
    required this.goods,
    required this.left,
    required this.controller,
    required this.onChanged,
  });

  final PurchaseLine line;
  final bool goods;
  final double left;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          line.description,
          style: theme.textTheme.titleSmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          'Billed ${formatQty(line.qty)} ${line.unit} × ${formatMoney(line.rate)}'
          '${line.returnedQty > 0 ? ' · returned ${formatQty(line.returnedQty)}' : ''}'
          ' · GST ${formatPercent(line.gstRate)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    final field = TextFormField(
      controller: controller,
      decoration: InputDecoration(
        labelText: goods ? 'Return qty' : 'Amount before GST',
        helperText: 'Max ${goods ? formatQty(left) : formatMoney(left)}',
        isDense: true,
        suffixText: goods ? line.unit : null,
        errorMaxLines: 2,
      ),
      keyboardType: decimalKeyboard,
      inputFormatters: [decimalInput(decimals: goods ? 3 : 2)],
      onChanged: (_) => onChanged(),
      validator: (v) {
        final q = parseNumber(v ?? '');
        if (q == null) return null;
        if (q < 0) return 'Cannot be negative';
        return q > left + 0.0005
            ? 'Max ${goods ? formatQty(left) : formatMoney(left)}'
            : null;
      },
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, c) => c.maxWidth >= 560
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: info),
                    const SizedBox(width: 16),
                    SizedBox(width: 180, child: field),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [info, const SizedBox(height: 8), field],
                ),
        ),
      ),
    );
  }
}
