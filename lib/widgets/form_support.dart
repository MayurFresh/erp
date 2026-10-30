import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/validators.dart';
import 'states.dart';

export '../core/validators.dart';

/// Maps `VALIDATION_ERROR` details onto form fields via `forceErrorText`.
mixin ServerFieldErrors<T extends StatefulWidget> on State<T> {
  Map<String, String> serverErrors = const {};

  String? serverError(String field) => serverErrors[field];

  void clearServerError(String field) {
    if (!serverErrors.containsKey(field)) return;
    setState(() => serverErrors = Map.of(serverErrors)..remove(field));
  }

  /// Shows [error] in a SnackBar and attaches field messages to fields.
  void showSubmitError(Object error) {
    final api = apiError(error);
    if (api != null && api.fieldErrors.isNotEmpty) {
      setState(() => serverErrors = Map.of(api.fieldErrors));
    }
    showErrorSnackBar(context, error);
  }
}

/// Digits with up to [decimals] decimal places (optionally signed). Typed or
/// pasted grouping ("1,00,000") is accepted and stripped; letters are
/// rejected. [max] defaults to the contract limit (1e9 for quantities with
/// 3 decimals, 1e12 otherwise).
TextInputFormatter decimalInput({
  int decimals = 2,
  bool signed = false,
  double? max,
}) => NumberInputFormatter(
  decimals: decimals,
  signed: signed,
  max: max ?? (decimals == 3 ? kMaxQty : kMaxMoney),
);

const TextInputType decimalKeyboard = TextInputType.numberWithOptions(
  decimal: true,
);

double? parseNumber(String text) => parseIndianNumber(text);

String? requiredField(String? value, [String label = 'This field']) =>
    (value == null || value.trim().isEmpty) ? '$label is required' : null;

String? requiredNumber(
  String? value, {
  String label = 'Value',
  double? min,
  double max = kMaxMoney,
}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return '$label is required';
  final number = parseIndianNumber(text);
  if (number == null) return 'Enter a number';
  if (number.abs() > max) return '$label is too large';
  if (min != null && number < min) return '$label must be at least $min';
  return null;
}

String? optionalNumber(String? value, {double? min, double? max}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  final number = parseIndianNumber(text);
  if (number == null) return 'Enter a number';
  if (number.abs() > kMaxMoney) return 'Value is too large';
  if (min != null && number < min) return 'Must be at least $min';
  if (max != null && number > max) return 'Must be at most $max';
  return null;
}

String? trimmedOrNull(String text) {
  final value = text.trim();
  return value.isEmpty ? null : value;
}
