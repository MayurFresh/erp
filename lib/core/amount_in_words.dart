/// Indian-style amounts in words (lakh / crore grouping), e.g.
/// `264910` → `Rupees Two Lakh Sixty-Four Thousand Nine Hundred Ten Only`.
library;

const List<String> _ones = [
  'Zero',
  'One',
  'Two',
  'Three',
  'Four',
  'Five',
  'Six',
  'Seven',
  'Eight',
  'Nine',
  'Ten',
  'Eleven',
  'Twelve',
  'Thirteen',
  'Fourteen',
  'Fifteen',
  'Sixteen',
  'Seventeen',
  'Eighteen',
  'Nineteen',
];

const List<String> _tens = [
  '',
  '',
  'Twenty',
  'Thirty',
  'Forty',
  'Fifty',
  'Sixty',
  'Seventy',
  'Eighty',
  'Ninety',
];

/// 0–99, hyphenated: `64` → `Sixty-Four`.
String _belowHundred(int n) {
  if (n < 20) return _ones[n];
  final unit = n % 10;
  return unit == 0 ? _tens[n ~/ 10] : '${_tens[n ~/ 10]}-${_ones[unit]}';
}

/// 0–999; empty for 0.
String _belowThousand(int n) {
  final parts = <String>[];
  if (n >= 100) parts.add('${_ones[n ~/ 100]} Hundred');
  if (n % 100 != 0) parts.add(_belowHundred(n % 100));
  return parts.join(' ');
}

/// A whole number in words using crore, lakh and thousand; `0` → `Zero`.
String integerInWords(int n) {
  if (n < 0) return 'Minus ${integerInWords(-n)}';
  if (n == 0) return _ones[0];
  final parts = <String>[];
  final crore = n ~/ 10000000;
  // Amounts of 100 crore and more read as "One Hundred Crore" etc.
  if (crore > 0) parts.add('${integerInWords(crore)} Crore');
  final lakh = (n ~/ 100000) % 100;
  if (lakh > 0) parts.add('${_belowHundred(lakh)} Lakh');
  final thousand = (n ~/ 1000) % 100;
  if (thousand > 0) parts.add('${_belowHundred(thousand)} Thousand');
  final rest = n % 1000;
  if (rest > 0) parts.add(_belowThousand(rest));
  return parts.join(' ');
}

/// `1234.5` → `Rupees One Thousand Two Hundred Thirty-Four and Fifty Paise
/// Only`. Rounded to paise; negative amounts are prefixed with "Minus".
String amountInWords(num amount) {
  final totalPaise = (amount.abs() * 100).round();
  final rupees = totalPaise ~/ 100;
  final paise = totalPaise % 100;
  final sign = amount < 0 && totalPaise > 0 ? 'Minus ' : '';
  if (rupees == 0 && paise > 0) {
    return '$sign${_belowHundred(paise)} Paise Only';
  }
  final words = 'Rupees ${integerInWords(rupees)}';
  final paiseWords = paise == 0 ? '' : ' and ${_belowHundred(paise)} Paise';
  return '$sign$words$paiseWords Only';
}
