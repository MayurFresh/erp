import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../items/item_model.dart' show gstRates;
import 'tax_models.dart';
import 'tax_repository.dart';

/// Dropdown of the GST rates valid on [date] for [kind] (`goods`/`services`,
/// null = any). A [value] that is not on offer (a legacy rate on an old
/// record) stays visible, labelled "legacy", so it is never silently changed.
/// While the rates load, or when they cannot be loaded, the standard slabs
/// are offered.
class GstRatePicker extends ConsumerWidget {
  const GstRatePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.date,
    this.kind,
    this.enabled = true,
    this.errorText,
    this.label = 'GST rate',
  });

  final double? value;
  final ValueChanged<double?>? onChanged;

  /// `YYYY-MM-DD`; null = today (server default).
  final String? date;
  final String? kind;
  final bool enabled;
  final String? errorText;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rates = ref.watch(gstRatesProvider((date, kind, false)));
    final offered = rates.maybeWhen(
      data: (rows) => rows.map((r) => r.rate).toSet().toList(),
      orElse: () => gstRates.where((r) => r != 12 && r != 28).toList(),
    )..sort();
    return DropdownButtonFormField<double>(
      key: ValueKey('gst-${value ?? 'none'}-${offered.length}'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, errorText: errorText),
      items: [
        for (final r in offered)
          DropdownMenuItem(value: r, child: Text(formatPercent(r))),
        if (value != null && !offered.contains(value))
          DropdownMenuItem(
            value: value,
            enabled: false,
            child: Text('${formatPercent(value)} (legacy)'),
          ),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}

/// Dropdown of TDS sections valid on [date]. Includes a "No TDS" choice
/// (value null) and an "unverified" badge on sections not yet verified.
class TdsSectionPicker extends ConsumerWidget {
  const TdsSectionPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.date,
    this.enabled = true,
    this.label = 'TDS section',
    this.errorText,
  });

  final String? value;
  final ValueChanged<TdsSection?>? onChanged;
  final String? date;
  final bool enabled;
  final String label;
  final String? errorText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(tdsSectionsProvider((date, true)));
    final rows = sections.value ?? const <TdsSection>[];
    final known = rows.any((s) => s.id == value);
    return DropdownButtonFormField<String?>(
      key: ValueKey('tds-${value ?? 'none'}-${rows.length}'),
      initialValue: known ? value : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        errorText: errorText,
        helperText: sections.isLoading ? 'Loading sections…' : null,
      ),
      selectedItemBuilder: (context) => [
        const Text('No TDS'),
        for (final s in rows)
          Text(s.display, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('No TDS')),
        for (final s in rows)
          DropdownMenuItem<String?>(
            value: s.id,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    s.display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!s.verified) ...[
                  const SizedBox(width: 8),
                  const UnverifiedBadge(),
                ],
              ],
            ),
          ),
      ],
      onChanged: enabled
          ? (id) => onChanged?.call(
              id == null ? null : rows.firstWhere((s) => s.id == id),
            )
          : null,
    );
  }
}

/// Small amber "unverified" label for statutory data not yet checked.
class UnverifiedBadge extends StatelessWidget {
  const UnverifiedBadge({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
    message:
        'This rate comes from a secondary source. Verify before relying '
        'on it.',
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'unverified',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.amber.shade900,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}
