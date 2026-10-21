import 'package:intl/intl.dart';

final NumberFormat _rupees = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);

final NumberFormat _amount = NumberFormat('#,##,##0.00', 'en_IN');
final NumberFormat _quantity = NumberFormat('#,##,##0.###', 'en_IN');
final NumberFormat _plain = NumberFormat('0.###', 'en_IN');
final DateFormat _date = DateFormat('dd MMM yyyy');
final DateFormat _dateTime = DateFormat('dd MMM yyyy, hh:mm a');
final DateFormat _apiDate = DateFormat('yyyy-MM-dd');

/// `123456.5` → `₹1,23,456.50` (Indian digit grouping).
String formatMoney(num? amount) => _rupees.format(amount ?? 0);

/// `123456.5` → `1,23,456.50` (no currency symbol, e.g. for PDFs).
String formatAmount(num? amount) => _amount.format(amount ?? 0);

/// `1234.5` → `1,234.5`; up to 3 decimals, no trailing zeros.
String formatQty(num? qty) => _quantity.format(qty ?? 0);

/// `18` → `18%`, `0.25` → `0.25%`.
String formatPercent(num? value) => '${_plain.format(value ?? 0)}%';

/// Number without grouping, for pre-filling text fields (`100`, `12.5`).
String formatPlain(num? value) => value == null ? '' : _plain.format(value);

/// Accepts `YYYY-MM-DD` or ISO timestamps; returns `21 Oct 2026`.
String formatDate(Object? value) {
  final date = value is DateTime
      ? value
      : DateTime.tryParse(value?.toString() ?? '');
  return date == null ? '' : _date.format(date.toLocal());
}

String formatDateTime(DateTime? value) =>
    value == null ? '' : _dateTime.format(value.toLocal());

/// `YYYY-MM-DD` as used by the API.
String apiDate(DateTime date) => _apiDate.format(date);
