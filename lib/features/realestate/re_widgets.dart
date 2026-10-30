import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../widgets/states.dart';
import '../../widgets/layout.dart';
import 're_models.dart';
import 're_repository.dart';

export '../construction/common/c_widgets.dart'
    show
        BottomBarLayout,
        CGate,
        CListCard,
        CPage,
        DateField,
        StatusChips,
        bigButton,
        confirm,
        isPhone,
        parseApiDate,
        showReasonDialog,
        showSuccess,
        today;

Widget unitStatusPill(UnitStatus s) => Pill(s.label, color: s.color);

Widget bookingStatusPill(BookingStatus s) => Pill(s.label, color: s.color);

Widget demandStatusPills(Demand d) => Wrap(
  spacing: 6,
  runSpacing: 4,
  children: [
    if (d.isCancelled)
      Pill('Cancelled', color: Colors.red.shade700)
    else
      Pill(d.paymentLabel, color: d.paymentColor()),
  ],
);

/// Picks a project. With [required] `false` it offers "All projects"
/// (`null`) for filters.
class ProjectField extends ConsumerWidget {
  const ProjectField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Project',
    this.required = true,
    this.enabled = true,
    this.errorText,
    this.autoSelectOnly = true,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  final bool required;
  final bool enabled;
  final String? errorText;

  /// Selects the project when there is just one and none is chosen.
  final bool autoSelectOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookup = ref.watch(projectOptionsProvider);
    final options = lookup.value ?? const <ProjectOption>[];
    if (required &&
        autoSelectOnly &&
        enabled &&
        value == null &&
        options.length == 1) {
      final only = options.single.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) onChanged(only);
      });
    }
    final selected = options.any((o) => o.id == value) ? value : null;
    return DropdownButtonFormField<String?>(
      key: ValueKey('project-$label-$selected-${options.length}'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.apartment_outlined),
        errorText: errorText,
        helperText: lookup.isLoading && !lookup.hasValue
            ? 'Loading…'
            : lookup.hasError
            ? apiErrorMessage(lookup.error!)
            : null,
        helperMaxLines: 2,
        suffixIcon: lookup.hasError
            ? IconButton(
                tooltip: 'Reload projects',
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(projectOptionsProvider),
              )
            : null,
      ),
      items: [
        if (!required)
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All projects'),
          ),
        for (final o in options)
          DropdownMenuItem<String?>(
            value: o.id,
            child: Text(o.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled ? onChanged : null,
      validator: required ? (v) => v == null ? 'Choose a project' : null : null,
    );
  }
}

String apiErrorMessage(Object error) =>
    error is ApiException ? error.message : error.toString();

/// Run a write; show the error as a snackbar on failure. `true` if it worked.
Future<bool> guarded(BuildContext context, Future<void> Function() call) async {
  try {
    await call();
    return true;
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
    return false;
  }
}

/// A coloured rectangle used as the legend of the stacking view.
class LegendDot extends StatelessWidget {
  const LegendDot(this.status, {super.key});

  final UnitStatus status;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: status.color,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
      const SizedBox(width: 6),
      Text(status.label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

/// Wrapped label/value facts, for detail cards and dialogs.
class FactsWrap extends StatelessWidget {
  const FactsWrap({super.key, required this.facts});

  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 24,
    runSpacing: 12,
    children: [for (final f in facts) LabeledValue(f.$1, f.$2)],
  );
}
