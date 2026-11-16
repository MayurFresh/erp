import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';

double round2(double v) => (v * 100).roundToDouble() / 100;

/// A discount on the whole bill: a rupee amount or a percent of the bill.
class BillDiscount {
  const BillDiscount({this.value = 0, this.isPercent = false});

  final double value;
  final bool isPercent;

  bool get isZero => value <= 0;
}

/// One document line as the form shows it, before any bill discount.
class BillLine {
  const BillLine({
    required this.qty,
    required this.rate,
    this.discountPct = 0,
    this.discountAmount = 0,
  });

  final double qty;
  final double rate;
  final double discountPct;
  final double discountAmount;

  double get gross => round2(qty * rate);
  double get ownDiscount =>
      discountAmount > 0 ? discountAmount : round2(gross * discountPct / 100);

  /// Value after the line's own discount, before the bill discount and tax.
  double get taxable => round2((gross - ownDiscount).clamp(0, double.infinity));
}

/// The rupee amount a bill discount takes off a bill of [subtotal]. Never more
/// than the bill.
double billDiscountTotal(double subtotal, BillDiscount d) {
  if (d.isZero || subtotal <= 0) return 0;
  final raw = d.isPercent ? subtotal * d.value.clamp(0, 100) / 100 : d.value;
  return round2(raw.clamp(0, subtotal));
}

/// Splits [total] over lines in proportion to their taxable values. Each share
/// is rounded to paise and the last line with value takes the remainder, so the
/// shares add up to exactly [total].
List<double> spreadDiscount(List<double> taxables, double total) {
  final sum = taxables.fold<double>(0, (a, b) => a + b);
  final shares = List<double>.filled(taxables.length, 0);
  if (total <= 0 || sum <= 0) return shares;
  final last = taxables.lastIndexWhere((t) => t > 0);
  var given = 0.0;
  for (var i = 0; i < taxables.length; i++) {
    if (taxables[i] <= 0) continue;
    if (i == last) {
      shares[i] = round2(total - given);
    } else {
      shares[i] = round2(total * taxables[i] / sum);
      given = round2(given + shares[i]);
    }
    if (shares[i] > taxables[i]) shares[i] = taxables[i];
  }
  return shares;
}

/// The fixed rupee discount to send for each line: its own discount plus its
/// share of the bill discount. GST is then charged on the reduced value.
List<double> fixedDiscounts(List<BillLine> lines, BillDiscount d) {
  final taxables = [for (final l in lines) l.taxable];
  final total = billDiscountTotal(taxables.fold<double>(0, (a, b) => a + b), d);
  final shares = spreadDiscount(taxables, total);
  return [for (var i = 0; i < lines.length; i++) round2(lines[i].ownDiscount + shares[i])];
}

/// "Discount on bill" input: an amount or percent switch and one number.
class BillDiscountField extends StatelessWidget {
  const BillDiscountField({
    super.key,
    required this.controller,
    required this.isPercent,
    required this.onModeChanged,
    required this.onChanged,
    this.appliedAmount,
  });

  final TextEditingController controller;
  final bool isPercent;
  final ValueChanged<bool> onModeChanged;
  final VoidCallback onChanged;

  /// The rupee amount the discount comes to, shown as a hint.
  final double? appliedAmount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 200,
              child: TextFormField(
                key: const ValueKey('bill-discount'),
                controller: controller,
                keyboardType: decimalKeyboard,
                inputFormatters: <TextInputFormatter>[decimalInput(decimals: 2)],
                decoration: InputDecoration(
                  labelText: 'Discount on bill',
                  prefixText: isPercent ? null : '$moneySymbol ',
                  suffixText: isPercent ? '%' : null,
                ),
                onChanged: (_) => onChanged(),
              ),
            ),
            SegmentedButton<bool>(
              key: const ValueKey('bill-discount-mode'),
              segments: [
                ButtonSegment(value: false, label: Text(moneySymbol)),
                const ButtonSegment(value: true, label: Text('%')),
              ],
              selected: {isPercent},
              showSelectedIcon: false,
              onSelectionChanged: (s) => onModeChanged(s.first),
            ),
          ],
        ),
        if (appliedAmount != null && appliedAmount! > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Takes ${formatMoney(appliedAmount!)} off before tax, spread over the lines.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// A fixed discount as a percent of the line, for documents that only take a
/// percent (sales orders). Rounded to two places, so the tax can differ from
/// the exact amount by a few paise.
double discountPctFor(double fixed, double gross) =>
    gross > 0 ? round2(fixed / gross * 100).clamp(0, 100).toDouble() : 0;
