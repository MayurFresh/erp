import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'location_model.dart';
import 'locations_repository.dart';

/// "All locations" + the locations in the user's scope. Hidden if the
/// locations cannot be loaded (e.g. no `locations.view`).
class LocationFilter extends ConsumerWidget {
  const LocationFilter({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookup = ref.watch(locationsLookupProvider);
    if (lookup.hasError) return const SizedBox.shrink();
    final locations = lookup.value ?? const <Location>[];
    final selected = locations.any((l) => l.id == value) ? value : null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: DropdownButtonFormField<String?>(
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Location',
          isDense: true,
          prefixIcon: Icon(Icons.location_on_outlined),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All locations'),
          ),
          for (final location in locations)
            DropdownMenuItem<String?>(
              value: location.id,
              child: Text(
                location.displayName,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// A required location picker for forms (active locations only).
class LocationField extends ConsumerWidget {
  const LocationField({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.label = 'Location',
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String? errorText;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookup = ref.watch(locationsLookupProvider);
    final locations = (lookup.value ?? const <Location>[])
        .where((l) => l.isActive || l.id == value)
        .toList();
    final selected = locations.any((l) => l.id == value) ? value : null;
    return DropdownButtonFormField<String>(
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: lookup.isLoading && !lookup.hasValue ? 'Loading…' : null,
        suffixIcon: lookup.hasError
            ? IconButton(
                tooltip: 'Reload locations',
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(locationsLookupProvider),
              )
            : null,
      ),
      forceErrorText:
          errorText ?? (lookup.hasError ? 'Could not load locations' : null),
      items: [
        for (final location in locations)
          DropdownMenuItem(
            value: location.id,
            child: Text(location.displayName, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
      validator: (v) => v == null ? '$label is required' : null,
    );
  }
}
