import 'number_input.dart';

export 'india_states.dart' show isValidGstin, validateGstin;
export 'number_input.dart';

/// Shared field validators. Each returns an error message or `null`.
/// Optional fields pass when empty; use [required] for mandatory ones.

final RegExp panPattern = RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]$');
final RegExp tanPattern = RegExp(r'^[A-Z]{4}[0-9]{5}[A-Z]$');
final RegExp ifscPattern = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');
final RegExp pincodePattern = RegExp(r'^[1-9][0-9]{5}$');
final RegExp mobilePattern = RegExp(r'^[6-9]\d{9}$');
final RegExp udyamPattern = RegExp(r'^UDYAM-[A-Z]{2}-\d{2}-\d{7}$');
final RegExp upiPattern = RegExp(r'^[\w.-]{2,}@[a-zA-Z]{2,}$');
final RegExp bankAccountPattern = RegExp(r'^\d{6,20}$');
final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? _empty(String? v, bool required, String label) {
  if ((v ?? '').trim().isEmpty) return required ? '$label is required' : null;
  return null;
}

/// Empty: null when optional, "required" otherwise. Else [check] on the
/// trimmed, upper-cased text.
String? _req(
  String? v,
  bool required,
  String label,
  RegExp pattern,
  String message,
) {
  final t = v?.trim().toUpperCase() ?? '';
  if (t.isEmpty) return required ? '$label is required' : null;
  return pattern.hasMatch(t) ? null : message;
}

bool _isEmpty(String? v) => (v ?? '').trim().isEmpty;

String? requiredValue(String? value, [String label = 'This field']) =>
    _isEmpty(value) ? '$label is required' : null;

String? maxLength(String? value, int max, [String label = 'This field']) =>
    (value ?? '').trim().length > max
    ? '$label must be at most $max characters'
    : null;

/// Name or title: 1-200 characters.
String? validateName(String? value, [String label = 'Name']) =>
    requiredValue(value, label) ?? maxLength(value, 200, label);

/// Notes / narration: up to 2000 characters.
String? validateNotes(String? value) => maxLength(value, 2000, 'Notes');

String? validatePan(String? value, {bool isRequired = false}) => _req(
  value,
  isRequired,
  'PAN',
  panPattern,
  'Enter a valid PAN (ABCDE1234F)',
);

String? validateTan(String? value, {bool isRequired = false}) => _req(
  value,
  isRequired,
  'TAN',
  tanPattern,
  'Enter a valid TAN (ABCD12345E)',
);

String? validateIfsc(String? value, {bool isRequired = false}) => _req(
  value,
  isRequired,
  'IFSC',
  ifscPattern,
  'Enter a valid IFSC (HDFC0001234)',
);

String? validatePincode(String? value, {bool isRequired = false}) => _req(
  value,
  isRequired,
  'PIN code',
  pincodePattern,
  'Enter a 6-digit PIN code (not starting with 0)',
);

/// Indian mobile number: 10 digits starting 6-9 (an optional `+91`/`0`
/// prefix and spaces are ignored).
String? validateMobile(String? value, {bool isRequired = false}) {
  if (_isEmpty(value)) return isRequired ? 'Mobile number is required' : null;
  var d = value!.replaceAll(RegExp(r'[\s-]'), '');
  if (d.startsWith('+91')) d = d.substring(3);
  if (d.length == 11 && d.startsWith('0')) d = d.substring(1);
  if (d.length == 12 && d.startsWith('91')) d = d.substring(2);
  return mobilePattern.hasMatch(d) ? null : 'Enter a valid 10-digit mobile';
}

String? validateEmail(String? value, {bool required = true}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return required ? 'Email is required' : null;
  if (text.length > 254) return 'Enter a valid email';
  return _emailPattern.hasMatch(text) ? null : 'Enter a valid email';
}

/// Udyam registration number, e.g. `UDYAM-MH-12-1234567`.
String? validateUdyam(String? value, {bool isRequired = false}) => _req(
  value,
  isRequired,
  'Udyam number',
  udyamPattern,
  'Enter a valid Udyam number (UDYAM-MH-12-1234567)',
);

String? validateUpi(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  return upiPattern.hasMatch(text) ? null : 'Enter a valid UPI ID (name@bank)';
}

String? validateBankAccount(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  return bankAccountPattern.hasMatch(text) ? null : 'Use 6 to 20 digits';
}

/// GSTIN checksum (mod-36 weighted) over the first 14 characters.
bool gstinChecksumValid(String? gstin) {
  final g = gstin?.trim().toUpperCase() ?? '';
  if (g.length != 15) return false;
  const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  var sum = 0;
  for (var i = 0; i < 14; i++) {
    final v = chars.indexOf(g[i]);
    if (v < 0) return false;
    final product = v * (i.isEven ? 1 : 2);
    sum += product ~/ 36 + product % 36;
  }
  return chars[(36 - sum % 36) % 36] == g[14];
}

String? _numberError(
  String? value, {
  required bool isRequired,
  required String label,
  double? min,
  required double max,
  required int decimals,
}) {
  if (_isEmpty(value)) return isRequired ? '$label is required' : null;
  final n = parseIndianNumber(value);
  if (n == null) return 'Enter a number';
  if (min != null && n < min) return '$label must be at least $min';
  if (n.abs() > max) return '$label is too large';
  final fraction = value!.replaceAll(',', '').split('.');
  if (fraction.length > 1 && fraction[1].length > decimals) {
    return 'At most $decimals decimal places';
  }
  return null;
}

/// Money: 2 decimals, up to 1e12.
String? validateMoney(
  String? value, {
  bool isRequired = true,
  String label = 'Amount',
  double? min,
}) => _numberError(
  value,
  isRequired: isRequired,
  label: label,
  min: min,
  max: kMaxMoney,
  decimals: 2,
);

/// Quantity: 3 decimals, up to 1e9.
String? validateQty(
  String? value, {
  bool isRequired = true,
  String label = 'Quantity',
  double? min,
}) => _numberError(
  value,
  isRequired: isRequired,
  label: label,
  min: min,
  max: kMaxQty,
  decimals: 3,
);

/// Percent: 0-100, 2 decimals.
String? validatePercent(
  String? value, {
  bool isRequired = true,
  String label = 'Percent',
}) => _numberError(
  value,
  isRequired: isRequired,
  label: label,
  min: 0,
  max: kMaxPercent,
  decimals: 2,
);

/// Document dates: 2000-01-01 to today + 365 days.
final DateTime kMinDocDate = DateTime(2000);
DateTime maxDocDate([DateTime? now]) {
  final n = now ?? DateTime.now();
  return DateTime(n.year, n.month, n.day).add(const Duration(days: 365));
}

bool isDocDateAllowed(DateTime d, [DateTime? now]) =>
    !d.isBefore(kMinDocDate) && !d.isAfter(maxDocDate(now));

/// Lenient phone check (mobile or landline): 7-15 digits, optional `+`,
/// spaces, dashes and brackets.
String? validatePhone(String? value, {bool isRequired = false}) {
  final empty = _empty(value, isRequired, 'Phone');
  if (empty != null || _isEmpty(value)) return empty;
  final t = value!.trim();
  if (!RegExp(r'^\+?[\d\s\-()]+$').hasMatch(t)) return 'Enter a valid phone';
  final digits = t.replaceAll(RegExp(r'\D'), '').length;
  return digits >= 7 && digits <= 15 ? null : 'Enter a valid phone';
}
