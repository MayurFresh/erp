import 'package:intl/intl.dart';

import '../../core/money.dart';

/// Short number for chart axes, tiles and tooltips.
/// INR groups as K, L (lakh) and Cr (crore); every other currency uses K, M, B.
/// Follows the company currency set by `configureMoney`.
String formatCompact(num? value, {bool currency = true, int maxDecimals = 1}) {
  final v = (value ?? 0).toDouble();
  final abs = v.abs();
  final sign = v < 0 ? '-' : '';
  final prefix = currency ? _symbol() : '';
  String scaled(double n, String unit) {
    var s = n.toStringAsFixed(maxDecimals);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return '$sign$prefix$s$unit';
  }

  if (moneyCurrency == 'INR') {
    if (abs >= 1e7) return scaled(abs / 1e7, ' Cr');
    if (abs >= 1e5) return scaled(abs / 1e5, ' L');
    if (abs >= 1e3) return scaled(abs / 1e3, 'K');
  } else {
    if (abs >= 1e9) return scaled(abs / 1e9, 'B');
    if (abs >= 1e6) return scaled(abs / 1e6, 'M');
    if (abs >= 1e3) return scaled(abs / 1e3, 'K');
  }
  return scaled(abs, '');
}

String _symbol() {
  final code = moneyCurrency;
  if (code == 'INR') return '₹';
  try {
    return NumberFormat.simpleCurrency(name: code).currencySymbol;
  } catch (_) {
    return '$code ';
  }
}

/// Percent change from [previous] to [current]; null when there is nothing to
/// compare against.
double? percentChange(num? current, num? previous) {
  if (current == null || previous == null || previous == 0) return null;
  return (current - previous) / previous.abs() * 100;
}

/// `+12%`, `-4.5%`, or `0%`.
String formatDeltaPercent(double pct) {
  final abs = pct.abs();
  final text = abs >= 100
      ? abs.round().toString()
      : abs.toStringAsFixed(abs < 10 ? 1 : 0);
  final clean = text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  if (clean == '0') return '0%';
  return '${pct < 0 ? '-' : '+'}$clean%';
}

/// A rounded-up axis maximum so grid lines land on friendly numbers.
double niceCeil(double max) {
  if (max <= 0) return 1;
  var exp = 1.0;
  while (max / exp >= 10) {
    exp *= 10;
  }
  while (max / exp < 1) {
    exp /= 10;
  }
  final f = max / exp;
  final nice = f <= 1
      ? 1
      : f <= 2
      ? 2
      : f <= 2.5
      ? 2.5
      : f <= 5
      ? 5
      : 10;
  return nice * exp;
}

/// `2026-04` to `Apr`, or `Apr 26` when [withYear].
String monthLabel(String ym, {bool withYear = false}) {
  final p = ym.split('-');
  if (p.length < 2) return ym;
  final y = int.tryParse(p[0]) ?? 2000;
  final m = int.tryParse(p[1]) ?? 1;
  final d = DateTime(y, m);
  return DateFormat(withYear ? 'MMM yy' : 'MMM').format(d);
}
