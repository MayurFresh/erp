import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/picker_field.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../data/construction_repository.dart';
import '../models/common_models.dart';
import '../models/dpr_models.dart';
import '../models/labour_models.dart';
import '../models/material_models.dart';
import '../models/project_models.dart';

/// Minimum size of tap targets on site screens (gloves, sunlight).
const Size kTapTarget = Size(48, 48);

/// Big filled / outlined button styles for primary site actions.
final ButtonStyle bigButton = FilledButton.styleFrom(
  minimumSize: const Size(64, 52),
  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
);
final ButtonStyle bigOutlinedButton = OutlinedButton.styleFrom(
  minimumSize: const Size(64, 52),
  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
);

/// Below this content width forms stack and lists become cards.
const double kPhoneWidth = 600;

bool isPhone(BuildContext context) =>
    MediaQuery.sizeOf(context).width < kPhoneWidth;

/// Shows [child] only if the user has any of [anyOf]; a lock message
/// otherwise. Routes are also guarded by the router; this keeps a deep link
/// or a stale menu from showing a broken screen.
class CGate extends ConsumerWidget {
  const CGate({super.key, required this.anyOf, required this.child});

  final List<String> anyOf;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    if (session == null) return const LoadingView();
    if (!session.permissions.canAny(anyOf)) {
      return const EmptyView(
        icon: Icons.lock_outline,
        message:
            'You do not have access to this screen.\n'
            'Ask an administrator for access.',
      );
    }
    return child;
  }
}

/// A thick progress bar with the percentage next to it.
class PctBar extends StatelessWidget {
  const PctBar(
    this.pct, {
    super.key,
    this.height = 8,
    this.showLabel = true,
    this.color,
    this.label,
  });

  /// 0–100 (clamped).
  final double pct;
  final double height;
  final bool showLabel;
  final Color? color;

  /// Replaces the `45%` text.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = clampPct(pct);
    final barColor =
        color ?? (value >= 100 ? Colors.green.shade700 : theme.colorScheme.primary);
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: value / 100,
        minHeight: height,
        color: barColor,
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
      ),
    );
    if (!showLabel) return bar;
    return Row(
      children: [
        Expanded(child: bar),
        const SizedBox(width: 8),
        Text(
          label ?? '${formatQty(roundPct(value))}%',
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// One decimal for percentages.
double roundPct(double value) => (value * 10).round() / 10;

/// Budget vs actual for one cost head: label, amounts and a bar that turns
/// red when the actual exceeds the budget.
class BudgetBar extends StatelessWidget {
  const BudgetBar({
    super.key,
    required this.label,
    required this.budget,
    required this.actual,
  });

  final String label;
  final double budget;
  final double actual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final over = budget > 0 ? actual > budget + 0.004 : actual > 0;
    final pct = budget > 0 ? actual / budget * 100 : (actual > 0 ? 100.0 : 0.0);
    final color = over ? theme.colorScheme.error : Colors.green.shade700;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            Text(
              '${formatMoney(actual)} of ${formatMoney(budget)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: over ? theme.colorScheme.error : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        PctBar(
          pct,
          height: 10,
          color: color,
          label: budget > 0 ? '${formatQty(roundPct(pct))}%' : '—',
        ),
        if (over)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Over budget by ${formatMoney(actual - budget)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

Color _amber(BuildContext context) => Colors.orange.shade800;

Widget projectStatusPill(BuildContext context, ProjectStatus status) => Pill(
  status.label,
  color: switch (status) {
    ProjectStatus.planning => Colors.blueGrey,
    ProjectStatus.active => Colors.green.shade700,
    ProjectStatus.onHold => _amber(context),
    ProjectStatus.completed => Theme.of(context).colorScheme.primary,
  },
);

Widget indentStatusPill(BuildContext context, IndentStatus status) => Pill(
  status.label,
  color: switch (status) {
    IndentStatus.draft => Colors.blueGrey,
    IndentStatus.submitted => _amber(context),
    IndentStatus.approved => Colors.green.shade700,
    IndentStatus.rejected => Theme.of(context).colorScheme.error,
    IndentStatus.closed => Theme.of(context).colorScheme.primary,
  },
);

Widget issueStatusPill(BuildContext context, IssueStatus status) => Pill(
  status.label,
  color: status == IssueStatus.cancelled
      ? Theme.of(context).colorScheme.error
      : Colors.green.shade700,
);

Widget dprStatusPill(BuildContext context, DprStatus status) => Pill(
  status.label,
  color: switch (status) {
    DprStatus.draft => Colors.blueGrey,
    DprStatus.submitted => _amber(context),
    DprStatus.approved => Colors.green.shade700,
  },
);

Widget wageStatusPill(BuildContext context, WageSheetStatus status) => Pill(
  status.label,
  color: switch (status) {
    WageSheetStatus.draft => Colors.blueGrey,
    WageSheetStatus.approved => _amber(context),
    WageSheetStatus.paid => Colors.green.shade700,
    WageSheetStatus.cancelled => Theme.of(context).colorScheme.error,
  },
);

/// Required site (or site / store) dropdown. When the user can see exactly
/// one option it is selected automatically.
class SiteField extends ConsumerWidget {
  const SiteField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'Site',
    this.errorText,
    this.enabled = true,
    this.includeStores = false,
    this.required = true,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final String label;
  final String? errorText;
  final bool enabled;

  /// Also lists stores and warehouses (indents).
  final bool includeStores;

  /// With `false`, a "No site" option maps to `null`.
  final bool required;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = includeStores ? indentLocationsProvider : sitesProvider;
    final lookup = ref.watch(provider);
    final options = lookup.value ?? const <NamedRef>[];
    if (required && enabled && value == null && options.length == 1) {
      final only = options.single.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) onChanged(only);
      });
    }
    final selected = options.any((o) => o.id == value) ? value : null;
    return DropdownButtonFormField<String?>(
      key: ValueKey('site-$label-$selected-${options.length}'),
      initialValue: selected,
      isExpanded: true,
      itemHeight: 56,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.location_on_outlined),
        helperText: lookup.isLoading && !lookup.hasValue ? 'Loading…' : null,
        suffixIcon: lookup.hasError
            ? IconButton(
                tooltip: 'Reload sites',
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(provider),
              )
            : null,
      ),
      forceErrorText:
          errorText ?? (lookup.hasError ? 'Could not load sites' : null),
      items: [
        if (!required)
          const DropdownMenuItem<String?>(value: null, child: Text('No site')),
        for (final o in options)
          DropdownMenuItem<String?>(
            value: o.id,
            child: Text(o.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled ? onChanged : null,
      validator: (v) => required && v == null ? '$label is required' : null,
    );
  }
}

/// "All sites" + sites, for list filters.
class SiteFilter extends ConsumerWidget {
  const SiteFilter({
    super.key,
    required this.value,
    required this.onChanged,
    this.includeStores = false,
  });

  final String? value;
  final ValueChanged<String?> onChanged;
  final bool includeStores;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = includeStores ? indentLocationsProvider : sitesProvider;
    final lookup = ref.watch(provider);
    if (lookup.hasError) return const SizedBox.shrink();
    final options = lookup.value ?? const <NamedRef>[];
    final selected = options.any((o) => o.id == value) ? value : null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: DropdownButtonFormField<String?>(
        key: ValueKey('site-filter-$selected-${options.length}'),
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Site',
          isDense: true,
          prefixIcon: Icon(Icons.location_on_outlined),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All sites'),
          ),
          for (final o in options)
            DropdownMenuItem<String?>(
              value: o.id,
              child: Text(o.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// A date field that opens the date picker; [onCleared] adds a clear button
/// for optional dates.
class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.onCleared,
    this.firstDate,
    this.lastDate,
    this.errorText,
    this.enabled = true,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final VoidCallback? onCleared;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final String? errorText;
  final bool enabled;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final first = firstDate ?? DateTime(now.year - 3);
    final last = lastDate ?? DateTime(now.year + 3, 12, 31);
    var initial = value ?? DateUtils.dateOnly(now);
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked != null) onChanged(DateUtils.dateOnly(picked));
  }

  @override
  Widget build(BuildContext context) {
    final field = PickerField(
      label: label,
      value: value == null ? null : formatDate(value),
      icon: Icons.calendar_today_outlined,
      errorText: errorText,
      enabled: enabled,
      onTap: () => _pick(context),
    );
    if (onCleared == null || value == null || !enabled) return field;
    return Row(
      children: [
        Expanded(child: field),
        IconButton(
          tooltip: 'Clear $label',
          constraints: BoxConstraints.tight(kTapTarget),
          icon: const Icon(Icons.close),
          onPressed: onCleared,
        ),
      ],
    );
  }
}

/// `YYYY-MM-DD` → local date, or `null`.
DateTime? parseApiDate(String? value) {
  if (value == null || value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  return parsed == null ? null : DateUtils.dateOnly(parsed);
}

DateTime today() => DateUtils.dateOnly(DateTime.now());

/// [–] value [+] with 48 px buttons. Tapping the value lets the user type it.
class CountStepper extends StatelessWidget {
  const CountStepper({
    super.key,
    required this.value,
    required this.onChanged,
    this.step = 1,
    this.min = 0,
    this.max = 999,
    this.unit,
    this.label,
    this.enabled = true,
    this.compact = false,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double step;
  final double min;
  final double max;

  /// Shown after the value, e.g. `h`.
  final String? unit;

  /// For tooltips and the "type a value" dialog, e.g. `Masons`.
  final String? label;
  final bool enabled;

  /// Narrower value box (lists).
  final bool compact;

  void _set(double next) => onChanged(next.clamp(min, max).toDouble());

  Future<void> _type(BuildContext context) async {
    final controller = TextEditingController(text: formatPlain(value));
    final typed = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label ?? 'Value'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          decoration: InputDecoration(suffixText: unit),
          onSubmitted: (t) => Navigator.of(context).pop(double.tryParse(t)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(double.tryParse(controller.text)),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (typed != null) _set(typed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = unit == null
        ? formatQty(value)
        : '${formatQty(value)} $unit';
    final name = label ?? 'value';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          tooltip: 'Less $name',
          constraints: BoxConstraints.tight(kTapTarget),
          onPressed: enabled && value > min ? () => _set(value - step) : null,
          icon: const Icon(Icons.remove),
        ),
        InkWell(
          onTap: enabled ? () => _type(context) : null,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            constraints: BoxConstraints(
              minWidth: compact ? 44 : 56,
              minHeight: 48,
            ),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              text,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        IconButton.filledTonal(
          tooltip: 'More $name',
          constraints: BoxConstraints.tight(kTapTarget),
          onPressed: enabled && value < max ? () => _set(value + step) : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

/// Opens [builder] full screen on phones and as a centred dialog (max 560
/// wide) otherwise.
Future<T?> showAdaptiveDialog<T>(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext context) builder,
  double maxWidth = 560,
}) {
  return showDialog<T>(
    context: context,
    builder: (context) {
      final header = AppBar(
        automaticallyImplyLeading: false,
        title: Text(title),
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      );
      final body = Scaffold(appBar: header, body: builder(context));
      if (MediaQuery.sizeOf(context).width < kPhoneWidth) {
        return Dialog.fullscreen(child: body);
      }
      return Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 720),
          child: body,
        ),
      );
    },
  );
}

/// Scrollable content with a bar of buttons pinned to the bottom (phones
/// keep Save / Submit within thumb reach).
class BottomBarLayout extends StatelessWidget {
  const BottomBarLayout({
    super.key,
    required this.child,
    required this.bar,
    this.maxWidth = 1000,
  });

  final Widget child;
  final Widget bar;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: child),
        Material(
          elevation: 6,
          color: scheme.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: bar,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Scrolling, centred page body with a width limit.
class CPage extends StatelessWidget {
  const CPage({super.key, required this.children, this.maxWidth = 1000});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.all(isPhone(context) ? 12 : 16),
    child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// Phone card for list rows: title + trailing amount, detail lines, pills
/// and an optional progress bar.
class CListCard extends StatelessWidget {
  const CListCard({
    super.key,
    required this.title,
    this.subtitle,
    this.details = const [],
    this.trailing,
    this.pills,
    this.progress,
    this.onTap,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final List<String> details;
  final String? trailing;
  final Widget? pills;
  final double? progress;
  final VoidCallback? onTap;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: theme.textTheme.titleMedium,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (trailing != null) ...[
                            const SizedBox(width: 8),
                            Text(
                              trailing!,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: muted,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      for (final line in details)
                        Text(
                          line,
                          style: theme.textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (pills != null) ...[const SizedBox(height: 6), pills!],
                      if (progress != null) ...[
                        const SizedBox(height: 8),
                        PctBar(progress!),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A green confirmation banner (e.g. after saving attendance).
void showSuccess(BuildContext context, String message) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.green.shade800,
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        showCloseIcon: true,
        closeIconColor: scheme.surface,
      ),
    );
}

/// Asks a yes/no question; `true` if confirmed.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Not now',
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      scrollable: true,
      content: SizedBox(width: 420, child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

/// A titled block of label/value facts that wraps on narrow screens.
class FactsWrap extends StatelessWidget {
  const FactsWrap({super.key, required this.facts});

  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 32,
    runSpacing: 12,
    children: [
      for (final (label, value) in facts)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: LabeledValue(label, value),
        ),
    ],
  );
}

/// "All" + one chip per option, single select (`null` = all). Chips keep a
/// 48 px tap target.
class StatusChips<T> extends StatelessWidget {
  const StatusChips({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.allLabel = 'All',
  });

  final T? value;

  /// Value → label, in display order.
  final Map<T, String> options;
  final ValueChanged<T?> onChanged;
  final String allLabel;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 0,
    children: [
      ChoiceChip(
        label: Text(allLabel),
        selected: value == null,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onSelected: (_) => onChanged(null),
      ),
      for (final MapEntry(:key, value: label) in options.entries)
        ChoiceChip(
          label: Text(label),
          selected: value == key,
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onSelected: (_) => onChanged(key),
        ),
    ],
  );
}
