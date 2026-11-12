import 'package:intl/intl.dart';

NumberFormat _rupees = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '₹',
  decimalDigits: 2,
);

NumberFormat _amount = NumberFormat('#,##,##0.00', 'en_IN');
NumberFormat _quantity = NumberFormat('#,##,##0.###', 'en_IN');
NumberFormat _plain = NumberFormat('0.###', 'en_IN');

const Map<String, String> _symbols = {
  'INR': '₹',
  'USD': r'$',
  'GBP': '£',
  'EUR': '€',
  'AUD': r'A$',
  'CAD': r'C$',
  'SGD': r'S$',
  'NPR': 'Rs ',
  'BDT': '৳',
  'LKR': 'Rs ',
  'ZAR': 'R',
  'KES': 'KSh ',
  'NGN': '₦',
};

/// Sets the currency and digit grouping used by every formatter here
/// (`INR`/`en_IN` by default). Called when the session loads and after the
/// business profile changes; an unknown locale falls back to `en_US`.
void configureMoney({String currency = 'INR', String locale = 'en_IN'}) {
  NumberFormat build(NumberFormat Function(String) make) {
    try {
      return make(locale);
    } catch (_) {
      return make('en_US');
    }
  }

  final indian = locale == 'en_IN';
  _rupees = build(
    (l) => NumberFormat.currency(
      locale: l,
      name: currency,
      symbol: _symbols[currency],
      decimalDigits: 2,
    ),
  );
  _amount = build((l) => NumberFormat(indian ? '#,##,##0.00' : '#,##0.00', l));
  _quantity = build(
    (l) => NumberFormat(indian ? '#,##,##0.###' : '#,##0.###', l),
  );
  _plain = build((l) => NumberFormat('0.###', l));
}

/// The symbol of the currency set by [configureMoney] (`₹`, `\$`).
String get moneySymbol => _rupees.currencySymbol;

/// The currency code set by [configureMoney].
String get moneyCurrency => _rupees.currencyName ?? 'INR';

final DateFormat _date = DateFormat('dd MMM yyyy');
final DateFormat _dateTime = DateFormat('dd MMM yyyy, hh:mm a');
final DateFormat _apiDate = DateFormat('yyyy-MM-dd');

/// `123456.5` → `₹1,23,456.50` (Indian grouping for INR; `\$123,456.50` for USD).
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
