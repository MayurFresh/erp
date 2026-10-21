import 'package:flutter/material.dart';

/// A read-only field that opens a picker when tapped. Takes part in [Form]
/// validation through [validator].
class PickerField extends StatelessWidget {
  const PickerField({
    super.key,
    required this.label,
    required this.onTap,
    this.value,
    this.errorText,
    this.validator,
    this.enabled = true,
    this.icon = Icons.search,
  });

  final String label;
  final String? value;
  final VoidCallback onTap;
  final String? errorText;
  final String? Function()? validator;
  final bool enabled;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return FormField<String>(
      validator: (_) => validator?.call(),
      builder: (field) => InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(4),
        child: InputDecorator(
          isEmpty: value == null,
          decoration: InputDecoration(
            labelText: label,
            enabled: enabled,
            errorText: errorText ?? field.errorText,
            suffixIcon: Icon(icon),
          ),
          child: value == null
              ? null
              : Text(value!, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
