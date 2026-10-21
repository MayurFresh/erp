import 'package:flutter/material.dart';

/// A compact dropdown for list filters; `null` is the "any" option.
class FilterDropdown<T> extends StatelessWidget {
  const FilterDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.anyLabel = 'All',
    this.icon,
    this.width = 200,
  });

  final String label;
  final T? value;

  /// Value → label, in display order.
  final Map<T, String> options;
  final ValueChanged<T?> onChanged;
  final String anyLabel;
  final IconData? icon;
  final double width;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: width),
    child: DropdownButtonFormField<T?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        prefixIcon: icon == null ? null : Icon(icon),
      ),
      items: [
        DropdownMenuItem<T?>(value: null, child: Text(anyLabel)),
        for (final MapEntry(:key, value: text) in options.entries)
          DropdownMenuItem<T?>(
            value: key,
            child: Text(text, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    ),
  );
}
