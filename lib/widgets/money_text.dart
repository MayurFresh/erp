import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_colors.dart';

final NumberFormat _inr = NumberFormat('#,##,##0.00', 'en_IN');
final NumberFormat _inr0 = NumberFormat('#,##,##0', 'en_IN');

/// `1234567.5` → `₹12,34,567.50`; negatives `−₹1,200.00` (true minus sign).
String formatMoneySigned(num? amount, {int decimals = 2}) {
  final v = (amount ?? 0).toDouble();
  final fmt = decimals == 0 ? _inr0 : _inr;
  final body = fmt.format(v.abs());
  final isZero = double.parse(v.abs().toStringAsFixed(decimals)) == 0;
  return '${v < 0 && !isZero ? '−' : ''}₹$body';
}

/// Lakh/crore shorthand: `₹4.20 lakh`, `₹1.25 crore`, below a lakh in full.
String formatMoneyCompact(num? amount) {
  final v = (amount ?? 0).toDouble();
  final a = v.abs();
  final sign = v < 0 ? '−' : '';
  if (a >= 1e7) return '$sign₹${(a / 1e7).toStringAsFixed(2)} crore';
  if (a >= 1e5) return '$sign₹${(a / 1e5).toStringAsFixed(2)} lakh';
  return formatMoneySigned(v, decimals: a == a.roundToDouble() ? 0 : 2);
}

/// An amount in rupees with Indian grouping and tabular figures. Negative
/// amounts carry a minus sign and (by default) the danger colour.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.amount, {
    super.key,
    this.style,
    this.decimals = 2,
    this.compact = false,
    this.colorNegative = true,
    this.textAlign,
    this.maxLines = 1,
  });

  final num? amount;
  final TextStyle? style;
  final int decimals;

  /// Use lakh/crore shorthand.
  final bool compact;
  final bool colorNegative;
  final TextAlign? textAlign;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final negative = (amount ?? 0) < 0;
    final text = compact
        ? formatMoneyCompact(amount)
        : formatMoneySigned(amount, decimals: decimals);
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: textAlign,
      style: base.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
        color: negative && colorNegative ? context.colors.danger : null,
      ),
    );
  }
}
