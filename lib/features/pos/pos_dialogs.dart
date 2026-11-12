import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/number_input.dart';
import '../../widgets/states.dart';
import 'pos_models.dart';
import 'pos_repository.dart';

/// Asks for one number. Returns null on cancel.
Future<double?> askNumber(
  BuildContext context, {
  required String title,
  required String label,
  double? initial,
  String? prefix,
  int decimals = 2,
  double? max,
}) async {
  final ctl = TextEditingController(
    text: initial == null ? '' : formatPlain(initial),
  );
  ctl.selection = TextSelection(baseOffset: 0, extentOffset: ctl.text.length);
  final out = await showDialog<double>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('ask-number'),
        controller: ctl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          NumberInputFormatter(decimals: decimals, max: max ?? kMaxMoney),
        ],
        decoration: InputDecoration(labelText: label, prefixText: prefix),
        onSubmitted: (v) => Navigator.of(context).pop(parseIndianNumber(v)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(parseIndianNumber(ctl.text)),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  ctl.dispose();
  return out;
}

/// Bill discount: a percentage or a rupee amount.
Future<BillDiscount?> askBillDiscount(
  BuildContext context,
  BillDiscount? current,
) {
  return showDialog<BillDiscount>(
    context: context,
    builder: (context) => _DiscountDialog(current: current),
  );
}

class _DiscountDialog extends StatefulWidget {
  const _DiscountDialog({this.current});

  final BillDiscount? current;

  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  late bool _pct = widget.current?.isPct ?? true;
  late final _ctl = TextEditingController(
    text: widget.current == null ? '' : formatPlain(widget.current!.value),
  );

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _done() {
    final v = parseIndianNumber(_ctl.text) ?? 0;
    Navigator.of(
      context,
    ).pop(_pct ? BillDiscount.pct(v) : BillDiscount.amount(v));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Bill discount'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Percent')),
            ButtonSegment(value: false, label: Text('Rupees')),
          ],
          selected: {_pct},
          onSelectionChanged: (s) => setState(() => _pct = s.first),
        ),
        const SizedBox(height: Space.md),
        TextField(
          key: const Key('discount-value'),
          controller: _ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [NumberInputFormatter(max: _pct ? 100 : kMaxMoney)],
          decoration: InputDecoration(
            labelText: _pct ? 'Discount %' : 'Discount amount',
            prefixText: _pct ? null : '₹ ',
          ),
          onSubmitted: (_) => _done(),
        ),
      ],
    ),
    actions: [
      if (widget.current != null)
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(const BillDiscount.amount(0)),
          child: const Text('Remove'),
        ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _done, child: const Text('Apply')),
    ],
  );
}

/// Cash put in or taken out of the drawer during the shift.
Future<bool> showCashMoveDialog(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (context) => _CashMoveDialog(sessionId: sessionId),
  );
  return done == true;
}

class _CashMoveDialog extends ConsumerStatefulWidget {
  const _CashMoveDialog({required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<_CashMoveDialog> createState() => _CashMoveDialogState();
}

class _CashMoveDialogState extends ConsumerState<_CashMoveDialog> {
  String _kind = 'out';
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amount = parseIndianNumber(_amount.text) ?? 0;
    if (amount <= 0 || _reason.text.trim().length < 2) {
      setState(() => _error = 'Enter an amount and a reason.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(posRepositoryProvider)
          .cashMove(widget.sessionId, _kind, amount, _reason.text.trim());
      ref.read(posRevisionProvider(PosKind.sales).notifier).bump();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Cash in or out'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'out', label: Text('Cash out')),
              ButtonSegment(value: 'in', label: Text('Cash in')),
            ],
            selected: {_kind},
            onSelectionChanged: _saving
                ? null
                : (s) => setState(() => _kind = s.first),
          ),
          const SizedBox(height: Space.md),
          TextField(
            key: const Key('move-amount'),
            controller: _amount,
            autofocus: true,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: const [NumberInputFormatter()],
            decoration: const InputDecoration(
              labelText: 'Amount',
              prefixText: '₹ ',
            ),
          ),
          const SizedBox(height: Space.sm),
          TextField(
            key: const Key('move-reason'),
            controller: _reason,
            enabled: !_saving,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Reason'),
          ),
          if (_error != null)
            Text(_error!, style: TextStyle(color: context.colors.danger)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}

/// Held bills at this counter's location; picking one resumes it.
Future<HeldBill?> showHeldBills(BuildContext context, String locationId) {
  return showDialog<HeldBill>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: _HeldList(locationId: locationId),
      ),
    ),
  );
}

class _HeldList extends ConsumerWidget {
  const _HeldList({required this.locationId});

  final String locationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final held = ref.watch(posHeldProvider(locationId));
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Held bills',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Flexible(
          child: AsyncValueView<List<HeldBill>>(
            value: held,
            onRetry: () => ref.invalidate(posHeldProvider(locationId)),
            data: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(Space.xl),
                    child: Text('No bills on hold.'),
                  )
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final h = list[i];
                      return ListTile(
                        key: Key('held-${h.id}'),
                        title: Text(
                          h.label.isEmpty ? 'Bill ${i + 1}' : h.label,
                        ),
                        subtitle: Text(
                          '${h.lineCount} lines  |  ${h.createdBy}  |  ${formatDateTime(h.createdAt)}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(formatMoney(h.total)),
                            IconButton(
                              tooltip: 'Discard',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                try {
                                  await ref
                                      .read(posRepositoryProvider)
                                      .discardHeld(h.id);
                                  ref
                                      .read(
                                        posRevisionProvider(
                                          PosKind.held,
                                        ).notifier,
                                      )
                                      .bump();
                                } catch (e) {
                                  if (context.mounted) {
                                    showErrorSnackBar(context, e);
                                  }
                                }
                              },
                            ),
                          ],
                        ),
                        onTap: () => Navigator.of(context).pop(h),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// Return goods against a counter bill: find the bill, choose quantities, refund.
Future<PosSale?> showReturnDialog(BuildContext context) {
  return showDialog<PosSale>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: const _ReturnFlow(),
      ),
    ),
  );
}

class _ReturnFlow extends ConsumerStatefulWidget {
  const _ReturnFlow();

  @override
  ConsumerState<_ReturnFlow> createState() => _ReturnFlowState();
}

class _ReturnFlowState extends ConsumerState<_ReturnFlow> {
  final _search = TextEditingController();
  List<Json> _found = const [];
  PosSale? _sale;
  final Map<String, TextEditingController> _qty = {};
  final _reason = TextEditingController();
  String _mode = 'cash';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    _reason.dispose();
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _find() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final page = await ref
          .read(posRepositoryProvider)
          .sales(q: _search.text.trim());
      if (mounted) setState(() => _found = page.data);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(String id) async {
    setState(() => _busy = true);
    try {
      final sale = await ref.read(posRepositoryProvider).sale(id);
      if (!mounted) return;
      for (final l in sale.lines) {
        _qty[l.invoiceLineId] = TextEditingController();
      }
      setState(() => _sale = sale);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final sale = _sale!;
    final lines = [
      for (final l in sale.lines)
        if ((parseIndianNumber(_qty[l.invoiceLineId]!.text) ?? 0) > 0)
          (
            lineId: l.invoiceLineId,
            qty: parseIndianNumber(_qty[l.invoiceLineId]!.text)!,
          ),
    ];
    if (lines.isEmpty) {
      setState(() => _error = 'Enter a quantity to return.');
      return;
    }
    if (_reason.text.trim().length < 3) {
      setState(() => _error = 'Give a reason.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final out = await ref
          .read(posRepositoryProvider)
          .returnSale(
            sale.id,
            lines: lines,
            reason: _reason.text.trim(),
            refundMode: _mode,
          );
      ref.read(posRevisionProvider(PosKind.sales).notifier).bump();
      if (mounted) Navigator.of(context).pop(out);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Return goods',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          if (_sale == null) ...[
            TextField(
              key: const Key('return-search'),
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Bill number or customer',
                suffixIcon: IconButton(
                  onPressed: _busy ? null : _find,
                  icon: const Icon(Icons.search),
                ),
              ),
              onSubmitted: (_) => _find(),
            ),
            const SizedBox(height: Space.sm),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in _found)
                    ListTile(
                      key: Key('sale-${s['id']}'),
                      title: Text(asString(s['number'])),
                      subtitle: Text(
                        '${asString(s['customerName'])}  |  ${formatDateTime(DateTime.tryParse(asString(s['createdAt']))?.toLocal())}',
                      ),
                      trailing: Text(formatMoney(asDouble(s['total']))),
                      onTap: _busy ? null : () => _pick(asString(s['id'])),
                    ),
                ],
              ),
            ),
          ] else ...[
            Text(
              '${_sale!.number}  |  ${_sale!.customerName}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: Space.sm),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final l in _sale!.lines)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.xs),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${l.description}\nsold ${formatQty(l.qty)}, returned ${formatQty(l.returnedQty)}',
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            child: TextField(
                              key: Key('return-qty-${l.invoiceLineId}'),
                              controller: _qty[l.invoiceLineId],
                              enabled: l.returnable > 0 && !_busy,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: const [
                                NumberInputFormatter(decimals: 3),
                              ],
                              decoration: InputDecoration(
                                labelText: 'Return',
                                isDense: true,
                                helperText: 'max ${formatQty(l.returnable)}',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            TextField(
              key: const Key('return-reason'),
              controller: _reason,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
            const SizedBox(height: Space.sm),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(labelText: 'Refund by'),
              items: [
                for (final m in posModes)
                  DropdownMenuItem(value: m, child: Text(posModeLabel(m))),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _mode = v ?? 'cash'),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(_error!, style: TextStyle(color: colors.danger)),
            ),
          if (_sale != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.md),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('return-submit'),
                  onPressed: _busy ? null : _submit,
                  child: const Text('Return and refund'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Keyboard shortcut key for tests and the counter.
const LogicalKeyboardKey kFocusSearchKey = LogicalKeyboardKey.f2;
const LogicalKeyboardKey kPayKey = LogicalKeyboardKey.f9;
