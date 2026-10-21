import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'states.dart';

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

/// Allows digits with up to [decimals] decimal places (optionally signed).
TextInputFormatter decimalInput({int decimals = 2, bool signed = false}) {
  final sign = signed ? '-?' : '';
  final fraction = decimals > 0 ? '(\\.\\d{0,$decimals})?' : '';
  return FilteringTextInputFormatter.allow(RegExp('^$sign\\d*$fraction'));
}

const TextInputType decimalKeyboard = TextInputType.numberWithOptions(
  decimal: true,
);

double? parseNumber(String text) => double.tryParse(text.trim());

String? requiredField(String? value, [String label = 'This field']) =>
    (value == null || value.trim().isEmpty) ? '$label is required' : null;

String? requiredNumber(String? value, {String label = 'Value', double? min}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return '$label is required';
  final number = double.tryParse(text);
  if (number == null) return 'Enter a number';
  if (min != null && number < min) return '$label must be at least $min';
  return null;
}

String? optionalNumber(String? value, {double? min, double? max}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  final number = double.tryParse(text);
  if (number == null) return 'Enter a number';
  if (min != null && number < min) return 'Must be at least $min';
  if (max != null && number > max) return 'Must be at most $max';
  return null;
}

final RegExp _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? validateEmail(String? value, {bool required = true}) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return required ? 'Email is required' : null;
  return _email.hasMatch(text) ? null : 'Enter a valid email';
}

String? trimmedOrNull(String text) {
  final value = text.trim();
  return value.isEmpty ? null : value;
}
