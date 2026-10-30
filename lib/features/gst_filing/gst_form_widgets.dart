import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../core/validators.dart';
import '../../widgets/states.dart';

/// A figure that copies its plain value (`1234.50`) when tapped.
class CopyAmount extends StatelessWidget {
  const CopyAmount({super.key, required this.label, required this.value});

  final String label;
  final double value;

  static String plain(double v) => v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Copy $label ${plain(value)}',
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: plain(value)));
        if (context.mounted) {
          showInfoSnackBar(context, 'Copied ${plain(value)}');
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$label ',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              TextSpan(
                text: formatAmount(value),
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Rupee text field that accepts blank (as 0) and rejects negatives.
class MoneyField extends StatelessWidget {
  const MoneyField({
    super.key,
    required this.controller,
    required this.label,
    this.isRequired = false,
  });

  final TextEditingController controller;
  final String label;
  final bool isRequired;

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    decoration: InputDecoration(labelText: label),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [moneyInput()],
    validator: (v) =>
        validateMoney(v, isRequired: isRequired, label: label, min: 0),
  );
}

/// Value of a [MoneyField]; blank is 0.
double money(TextEditingController c) => parseIndianNumber(c.text) ?? 0;
