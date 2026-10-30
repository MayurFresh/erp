import 'package:flutter/services.dart';

/// Input limits from the API contract.
const double kMaxMoney = 1e12;
const double kMaxQty = 1e9;
const double kMaxPercent = 100;

/// Parses Indian-style numbers: `1,00,000.50`, `₹ 2,500`, `-12`.
/// Returns `null` for empty text, letters or any other garbage.
double? parseIndianNumber(String? text) {
  if (text == null) return null;
  var t = text.trim().replaceAll(RegExp(r'[,\s ]'), '');
  if (t.startsWith('₹')) t = t.substring(1);
  if (t.isEmpty || !RegExp(r'^-?(\d+\.?\d*|\.\d+)$').hasMatch(t)) return null;
  return double.tryParse(t);
}

/// Digits only (no grouping), safe for `double.tryParse` elsewhere.
///
/// Typed or pasted commas, spaces and a leading `₹` are removed ("1,00,000"
/// becomes "100000"); letters are rejected; fraction digits are capped at
/// [decimals] and the value at [max] (absolute).
class NumberInputFormatter extends TextInputFormatter {
  const NumberInputFormatter({
    this.decimals = 2,
    this.signed = false,
    this.max = kMaxMoney,
  });

  final int decimals;
  final bool signed;
  final double max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text;
    var text = raw.replaceAll(RegExp(r'[,\s ₹]'), '');
    if (text.isEmpty) {
      return newValue.copyWith(
        text: '',
        selection: const TextSelection.collapsed(offset: 0),
      );
    }
    final fraction = decimals > 0 ? '(\\.\\d{0,$decimals})?' : '';
    final pattern = RegExp('^${signed ? '-?' : ''}\\d*$fraction\$');
    if (!pattern.hasMatch(text)) return oldValue;
    final value = double.tryParse(text);
    if (value != null && value.abs() > max) return oldValue;
    if (text == raw) return newValue;
    // Keep the caret after the same number of kept characters.
    final before = raw
        .substring(0, newValue.selection.baseOffset.clamp(0, raw.length))
        .replaceAll(RegExp(r'[,\s ₹]'), '')
        .length;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: before.clamp(0, text.length)),
    );
  }
}

/// Rupee amounts: up to 2 decimals, at most 1e12.
TextInputFormatter moneyInput({bool signed = false}) =>
    NumberInputFormatter(decimals: 2, signed: signed);

/// Quantities: up to 3 decimals, at most 1e9.
TextInputFormatter qtyInput({bool signed = false}) =>
    NumberInputFormatter(decimals: 3, signed: signed, max: kMaxQty);

/// Percentages: 0–100, up to 2 decimals.
TextInputFormatter percentInput() =>
    const NumberInputFormatter(decimals: 2, max: kMaxPercent);
