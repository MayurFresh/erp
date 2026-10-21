import 'package:flutter/material.dart';

import '../core/india_states.dart';

/// GST state picker. With [required] false, a "Not specified" entry maps to
/// `null`. Updating [value] from the parent updates the selection.
class StateDropdown extends StatelessWidget {
  const StateDropdown({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'State',
    this.required = true,
    this.helperText,
    this.errorText,
    this.enabled = true,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  final bool required;
  final String? helperText;
  final String? errorText;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final known = isValidStateCode(value);
    return DropdownButtonFormField<String?>(
      initialValue: known ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, helperText: helperText),
      forceErrorText: errorText,
      items: [
        if (!required)
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('Not specified'),
          ),
        for (final state in indiaStates)
          DropdownMenuItem<String?>(
            value: state.code,
            child: Text(state.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled ? onChanged : null,
      validator: (v) => required && v == null ? '$label is required' : null,
    );
  }
}
