import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/layout.dart';
import 'controls_models.dart';
import 'controls_repository.dart';

/// Cost centre picker for document forms (invoice, purchase, expense, credit
/// note, journal line). Required when the company says so
/// (`costCentreRequired`) or when [forceRequired] is set. Hidden when the
/// company has no cost centres and none is required.
///
/// [errorText] takes the server's `costCentreId` field error.
class CostCentreField extends ConsumerWidget {
  const CostCentreField({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.label = 'Cost centre',
    this.forceRequired = false,
    this.isDense = false,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String? errorText;
  final String label;
  final bool forceRequired;
  final bool isDense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookup = ref.watch(costCentresProvider(false));
    final required =
        forceRequired || (ref.watch(costCentreRequiredProvider).value ?? false);
    final all = lookup.value ?? const <CostCentre>[];
    final centres = all.where((c) => c.isActive || c.id == value).toList();
    if (centres.isEmpty && !required && !lookup.isLoading) {
      return const SizedBox.shrink();
    }
    final selected = centres.any((c) => c.id == value) ? value : null;
    return DropdownButtonFormField<String>(
      key: ValueKey('cc-$selected-${centres.length}'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        isDense: isDense ? true : null,
        helperText: lookup.isLoading && !lookup.hasValue ? 'Loading…' : null,
      ),
      forceErrorText:
          errorText ?? (lookup.hasError ? 'Could not load cost centres' : null),
      items: [
        if (!required)
          const DropdownMenuItem<String>(value: null, child: Text('None')),
        for (final c in centres)
          DropdownMenuItem(
            value: c.id,
            child: Text(c.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      validator: (v) => required && v == null ? '$label is required' : null,
      onChanged: onChanged,
    );
  }
}

/// A compact cost centre filter for report screens (`null` = all).
class CostCentreFilter extends ConsumerWidget {
  const CostCentreFilter({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookup = ref.watch(costCentresProvider(true));
    final centres = lookup.value ?? const <CostCentre>[];
    if (centres.isEmpty) return const SizedBox.shrink();
    final selected = centres.any((c) => c.id == value) ? value : null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: DropdownButtonFormField<String?>(
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Cost centre',
          isDense: true,
          prefixIcon: Icon(Icons.account_tree_outlined),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All cost centres'),
          ),
          for (final c in centres)
            DropdownMenuItem<String?>(
              value: c.id,
              child: Text(c.label, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// Read-only "Cost centre" card for detail screens; empty without an id.
class CostCentreCard extends ConsumerWidget {
  const CostCentreCard({super.key, required this.costCentreId});

  final String? costCentreId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = costCentreId;
    if (id == null || id.isEmpty) return const SizedBox.shrink();
    final centres = ref.watch(costCentresProvider(true)).asData?.value;
    final match = centres?.where((c) => c.id == id);
    final label = (match != null && match.isNotEmpty) ? match.first.label : id;
    return SectionCard(title: 'Cost centre', child: Text(label));
  }
}
