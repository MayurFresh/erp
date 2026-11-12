import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../core/number_input.dart';
import '../../widgets/states.dart';
import 'pos_cart.dart';
import 'pos_models.dart';

/// Result of a saved sale: the bill and whether to print it now.
class PayOutcome {
  const PayOutcome(this.sale, {required this.print});

  final PosSale sale;
  final bool print;
}

/// Saves the sale. Throws on failure; the sheet then stays open.
typedef SaveSale =
    Future<PosSale> Function(List<PaymentInput> payments, bool allowCredit);

/// Shows the pay sheet: a dialog on wide screens, a bottom sheet on phones.
Future<PayOutcome?> showPaySheet(
  BuildContext context, {
  required double total,
  required SaveSale onSave,
  required bool canCredit,
}) {
  final wide = MediaQuery.sizeOf(context).width >= Layout.wide;
  final body = PaySheet(total: total, onSave: onSave, canCredit: canCredit);
  if (wide) {
    return showDialog<PayOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: body,
        ),
      ),
    );
  }
  return showModalBottomSheet<PayOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => body,
  );
}

class PaySheet extends StatefulWidget {
  const PaySheet({
    super.key,
    required this.total,
    required this.onSave,
    this.canCredit = false,
  });

  final double total;
  final SaveSale onSave;
  final bool canCredit;

  @override
  State<PaySheet> createState() => _PaySheetState();
}

class _PaySheetState extends State<PaySheet> {
  final _ctl = {for (final m in posModes) m: TextEditingController()};
  final _cashFocus = FocusNode();
  bool _saving = false;
  bool _credit = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in _ctl.values) {
      c.addListener(() => setState(() {}));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cashFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    _cashFocus.dispose();
    super.dispose();
  }

  double _v(String mode) => parseIndianNumber(_ctl[mode]!.text) ?? 0;

  PayCalc get _calc => computePay(
    widget.total,
    cash: _v('cash'),
    upi: _v('upi'),
    card: _v('card'),
    other: _v('other'),
  );

  void _set(String mode, double v) {
    _ctl[mode]!.text = v <= 0 ? '' : formatPlain(roundMoney(v));
    _ctl[mode]!.selection = TextSelection.collapsed(
      offset: _ctl[mode]!.text.length,
    );
  }

  /// Puts what is still unpaid on [mode] (after the other modes).
  void _fill(String mode) {
    final others = posModes
        .where((m) => m != mode)
        .fold<double>(0, (s, m) => s + _v(m));
    _set(mode, widget.total - others);
  }

  bool get _canSave {
    if (_saving) return false;
    final c = _calc;
    if (c.nonCashOver) return false;
    return c.covered || (_credit && widget.canCredit);
  }

  Future<void> _save({required bool print}) async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final payments = [
      for (final m in posModes)
        if (_v(m) > 0) PaymentInput(m, _v(m)),
    ];
    try {
      final sale = await widget.onSave(payments, _credit);
      if (mounted) Navigator.of(context).pop(PayOutcome(sale, print: print));
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final calc = _calc;
    const quick = <double>[100, 200, 500, 2000];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_saving) Navigator.of(context).pop();
        },
        const SingleActivator(LogicalKeyboardKey.enter): () =>
            _save(print: false),
      },
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          Space.lg,
          Space.lg,
          Space.lg,
          Space.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Amount to pay',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                Text(
                  formatMoney(widget.total),
                  key: const Key('pay-total'),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            for (final m in posModes) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: Key('pay-$m'),
                      controller: _ctl[m],
                      focusNode: m == 'cash' ? _cashFocus : null,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: const [NumberInputFormatter()],
                      decoration: InputDecoration(
                        labelText: m == 'cash'
                            ? 'Cash given by customer'
                            : posModeLabel(m),
                        prefixText: '₹ ',
                        isDense: true,
                      ),
                    ),
                  ),
                  if (m != 'cash') ...[
                    const SizedBox(width: Space.sm),
                    TextButton(
                      key: Key('fill-$m'),
                      onPressed: _saving ? null : () => _fill(m),
                      child: const Text('Rest'),
                    ),
                  ],
                ],
              ),
              if (m == 'cash')
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.sm),
                  child: Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.xs,
                    children: [
                      ActionChip(
                        key: const Key('cash-exact'),
                        label: const Text('Exact'),
                        onPressed: _saving
                            ? null
                            : () => _set(
                                'cash',
                                widget.total -
                                    _v('upi') -
                                    _v('card') -
                                    _v('other'),
                              ),
                      ),
                      for (final q in quick)
                        ActionChip(
                          label: Text('₹${q.toInt()}'),
                          onPressed: _saving ? null : () => _set('cash', q),
                        ),
                    ],
                  ),
                )
              else
                const SizedBox(height: Space.sm),
            ],
            const Divider(),
            _line(
              context,
              'Change to give',
              calc.change,
              key: const Key('pay-change'),
              strong: true,
              color: calc.change > 0 ? colors.success : null,
            ),
            if (calc.short > 0.004)
              _line(
                context,
                'Still to pay',
                calc.short,
                key: const Key('pay-short'),
                color: colors.danger,
              ),
            if (calc.nonCashOver)
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(
                  'UPI, card and other are more than the bill.',
                  style: TextStyle(color: colors.danger),
                ),
              ),
            if (widget.canCredit)
              CheckboxListTile(
                key: const Key('pay-credit'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _credit,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _credit = v == true),
                title: const Text(
                  'Keep the balance as credit for this customer',
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Text(_error!, style: TextStyle(color: colors.danger)),
              ),
            const SizedBox(height: Space.md),
            Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton(
                  key: const Key('pay-cancel'),
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Back'),
                ),
                OutlinedButton(
                  key: const Key('pay-save'),
                  onPressed: _canSave ? () => _save(print: false) : null,
                  child: const Text('Save'),
                ),
                FilledButton(
                  key: const Key('pay-save-print'),
                  onPressed: _canSave ? () => _save(print: true) : null,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save and print'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(
    BuildContext context,
    String label,
    double v, {
    Key? key,
    bool strong = false,
    Color? color,
  }) {
    final style =
        (strong
                ? Theme.of(context).textTheme.titleMedium
                : Theme.of(context).textTheme.bodyMedium)
            ?.copyWith(
              color: color,
              fontWeight: strong ? FontWeight.w700 : null,
            );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(formatMoney(v), key: key, style: style),
        ],
      ),
    );
  }
}
