import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../widgets/search_picker.dart';
import '../data/construction_repository.dart';
import '../models/project_models.dart';

/// Searches the BOQ of [projectId] (code or description).
Future<BoqLine?> pickBoqLine(
  BuildContext context,
  WidgetRef ref, {
  required List<BoqLine> lines,
}) {
  return showSearchPicker<BoqLine>(
    context: context,
    title: 'Choose a BOQ line',
    hintText: 'Search code or description',
    emptyMessage: 'No BOQ lines match.',
    search: (q) async {
      final query = q.toLowerCase();
      if (query.isEmpty) return lines;
      return lines
          .where(
            (l) =>
                l.code.toLowerCase().contains(query) ||
                l.description.toLowerCase().contains(query),
          )
          .toList();
    },
    titleBuilder: (context, l) =>
        Text(l.label, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitleBuilder: (context, l) => Text(
      '${formatQty(l.qty)} ${l.unit} · done ${formatQty(l.executedQty)} '
      '(${formatQty(l.progressPct.roundToDouble())}%)',
    ),
  );
}

/// Optional BOQ line selector for the project that owns [siteId]: a tile
/// that opens [pickBoqLine], with a clear button. Hidden if the site has no
/// project or the project has no BOQ.
class BoqLineField extends ConsumerWidget {
  const BoqLineField({
    super.key,
    required this.siteId,
    required this.value,
    required this.onChanged,
    this.label = 'BOQ line (optional)',
    this.enabled = true,
  });

  final String? siteId;
  final String? value;
  final ValueChanged<BoqLine?> onChanged;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final site = siteId;
    if (site == null) return const SizedBox.shrink();
    final boq = ref.watch(boqForSiteProvider(site));
    final lines = boq.value ?? const <BoqLine>[];
    if (boq.hasValue && lines.isEmpty) return const SizedBox.shrink();
    BoqLine? selected;
    for (final l in lines) {
      if (l.id == value) selected = l;
    }
    final canPick = enabled && lines.isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: canPick
          ? () async {
              final picked = await pickBoqLine(context, ref, lines: lines);
              if (picked != null) onChanged(picked);
            }
          : null,
      child: InputDecorator(
        isEmpty: selected == null,
        decoration: InputDecoration(
          labelText: label,
          enabled: enabled,
          helperText: boq.isLoading && !boq.hasValue ? 'Loading BOQ…' : null,
          suffixIcon: selected != null && enabled
              ? IconButton(
                  tooltip: 'Clear BOQ line',
                  icon: const Icon(Icons.close),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.search),
        ),
        child: selected == null
            ? null
            : Text(
                selected.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
      ),
    );
  }
}
