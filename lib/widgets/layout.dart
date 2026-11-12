import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/app_colors.dart';
import '../core/business_profile.dart';
import '../core/design_tokens.dart';
import 'icon_badge.dart';

/// Width at which the shell switches from drawer to sidebar.
const double kWideLayout = 900;

/// Horizontal page gutter for the current width.
double pageGutter(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= Layout.wide
    ? Layout.pageGutterWide
    : Layout.pageGutterNarrow;

/// The page name the phone app bar is showing, so [PageHeader] need not
/// repeat it directly underneath.
class ShellTitle extends InheritedWidget {
  const ShellTitle({super.key, required this.title, required super.child});

  final String title;

  static String? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellTitle>()?.title;

  @override
  bool updateShouldNotify(ShellTitle oldWidget) => title != oldWidget.title;
}

/// Title row with actions at the top of a page; wraps on narrow screens.
///
/// The row is stretched to the full width explicitly: inside a `Column`
/// with the default centre alignment the children get loose constraints, and
/// a shrink-wrapped header ended up centred above a full-width list.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    final name = context.w(title);
    final repeated = ShellTitle.of(context) == name;
    if (repeated && subtitle == null && actions.isEmpty) {
      return const SizedBox(height: Space.sm);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, Space.md, gutter, Space.sm),
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Space.md,
          runSpacing: Space.xs,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width - gutter * 2,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!repeated)
                    Text(name, style: theme.textTheme.headlineSmall),
                  if (subtitle != null)
                    Text(
                      context.w(subtitle!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
          ],
        ),
      ),
    );
  }
}

/// Filter controls under a page header; wraps on narrow screens.
class FilterBar extends StatelessWidget {
  const FilterBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.sm),
      child: SizedBox(
        width: double.infinity,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.4,
          ),
          child: SingleChildScrollView(
            child: Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays children out as a grid: up to [maxColumns] per row on wide screens
/// (cells of at least [minCellWidth]), stacked on phones. A row with fewer
/// children than columns leaves its cells at a comfortable width instead of
/// stretching them across the page.
class FormRow extends StatelessWidget {
  const FormRow({
    super.key,
    required this.children,
    this.breakpoint = 560,
    this.maxColumns = 4,
    this.minCellWidth = 240,
    this.maxCellWidth = 520,
  });

  final List<Widget> children;
  final double breakpoint;
  final int maxColumns;
  final double minCellWidth;
  final double maxCellWidth;

  static const double gap = Space.md;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      if (children.length == 1 && width >= breakpoint) {
        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxCellWidth),
            child: children.first,
          ),
        );
      }
      if (width < breakpoint || children.length < 2) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: gap),
              children[i],
            ],
          ],
        );
      }
      final fit = ((width + gap) / (minCellWidth + gap)).floor();
      final columns = fit.clamp(1, maxColumns).clamp(1, children.length);
      final cell = ((width - gap * (columns - 1)) / columns).clamp(
        0.0,
        maxCellWidth,
      );
      return SizedBox(
        width: double.infinity,
        child: Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children) SizedBox(width: cell, child: child),
          ],
        ),
      );
    },
  );
}

/// Lays children out in rows of [columns], each child taking [span] columns
/// (clamped). Every row fills the full width, so the last row never leaves a
/// gap on the right.
class FlowGrid extends StatelessWidget {
  const FlowGrid({
    super.key,
    required this.columns,
    required this.children,
    this.gap = Space.md,
    this.equalHeight = false,
  });

  final int columns;
  final List<(int span, Widget child)> children;
  final double gap;

  /// Stretches a row's children to the tallest one. Only for children with a
  /// measurable height: charts and anything built on `LayoutBuilder` cannot
  /// report one.
  final bool equalHeight;

  @override
  Widget build(BuildContext context) {
    final rows = <List<(int, Widget)>>[];
    var cur = <(int, Widget)>[];
    var used = 0;
    for (final (span, child) in children) {
      final s = math.min(span, columns);
      if (used + s > columns) {
        rows.add(cur);
        cur = [];
        used = 0;
      }
      cur.add((s, child));
      used += s;
    }
    if (cur.isNotEmpty) rows.add(cur);
    return Column(
      children: [
        for (final (r, row) in rows.indexed) ...[
          if (r > 0) SizedBox(height: gap),
          _row(row),
        ],
      ],
    );
  }

  Widget _row(List<(int, Widget)> row) {
    final cells = Row(
      crossAxisAlignment: equalHeight
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.start,
      children: [
        for (final (i, (s, child)) in row.indexed) ...[
          if (i > 0) SizedBox(width: gap),
          Expanded(flex: s, child: child),
        ],
      ],
    );
    return equalHeight ? IntrinsicHeight(child: cells) : cells;
  }
}

/// A scrolling, width-limited column for forms and detail pages. Wide
/// screens use the available width up to [maxWidth]; [bottomBar] stays
/// pinned under the scrolling content (see [FormActionBar]).
class FormPage extends StatelessWidget {
  const FormPage({
    super.key,
    required this.children,
    this.maxWidth = Layout.contentMaxWidth,
    this.bottomBar,
  });

  final List<Widget> children;
  final double maxWidth;
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    final scroll = SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, Space.md, gutter, Space.lg),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth < Layout.formMinMaxWidth
                ? Layout.formMinMaxWidth
                : maxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
    if (bottomBar == null) return scroll;
    return Column(
      children: [
        Expanded(child: scroll),
        bottomBar!,
      ],
    );
  }
}

/// Sticky Save / Cancel strip for long forms; pass to [FormPage.bottomBar].
class FormActionBar extends StatelessWidget {
  const FormActionBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = pageGutter(context);
    return Material(
      color: theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: gutter,
              vertical: Space.sm,
            ),
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

(IconData, Accent) _sectionIcon(String title) {
  final t = title.toLowerCase();
  bool has(List<String> words) => words.any(t.contains);
  if (has(['pric', 'amount', 'payment', 'total', 'money', 'charge'])) {
    return (Icons.payments_outlined, Accent.amber);
  }
  if (has(['stock', 'inventory', 'warehouse', 'location', 'reorder'])) {
    return (Icons.inventory_2_outlined, Accent.sky);
  }
  if (has(['gst', 'tax', 'tds', 'gstin', 'compliance', 'e-invoice'])) {
    return (Icons.receipt_long_outlined, Accent.indigo);
  }
  if (has(['address', 'billing', 'shipping', 'place'])) {
    return (Icons.place_outlined, Accent.rose);
  }
  if (has(['contact', 'phone', 'email', 'people', 'user', 'customer'])) {
    return (Icons.contacts_outlined, Accent.sky);
  }
  if (has(['note', 'remark', 'terms', 'description', 'memo'])) {
    return (Icons.notes_outlined, Accent.indigo);
  }
  if (has(['line', 'item', 'product', 'material'])) {
    return (Icons.list_alt_outlined, Accent.teal);
  }
  if (has(['bank', 'account', 'ledger'])) {
    return (Icons.account_balance_outlined, Accent.amber);
  }
  if (has(['security', 'role', 'permission', 'access', 'password'])) {
    return (Icons.shield_outlined, Accent.rose);
  }
  if (has(['date', 'schedule', 'due', 'period'])) {
    return (Icons.event_outlined, Accent.sky);
  }
  return (Icons.article_outlined, Accent.teal);
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    required this.child,
    this.trailing,
    this.icon,
    this.accent,
    this.padding = const EdgeInsets.all(Space.md + 2),
  });

  final String? title;
  final Widget child;

  /// Action or count on the title row, e.g. a text button.
  final Widget? trailing;

  /// Badge icon for the title; inferred from the title when omitted.
  final IconData? icon;
  final Accent? accent;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final inferred = title == null ? null : _sectionIcon(title!);
    return Card(
      margin: const EdgeInsets.only(bottom: Space.md),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  IconBadge(
                    icon ?? inferred!.$1,
                    tone: accent ?? inferred!.$2,
                    size: 24,
                  ),
                  const SizedBox(width: Space.sm + 2),
                  Expanded(
                    child: Text(
                      title!,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: Space.md),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// A small coloured label (status, type). Prefer `StatusChip` for statuses;
/// this keeps the older `color` API and derives readable text from it.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = color ?? scheme.primary;
    // Darken (or lighten in dark mode) towards the text colour so the
    // label stays AA-readable on its own tint.
    final text = Color.lerp(base, scheme.onSurface, 0.45)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.14),
        borderRadius: Radii.smallAll,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: text,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

/// Label above a value, for detail pages.
class LabeledValue extends StatelessWidget {
  const LabeledValue(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 1),
        Text(value.isEmpty ? '—' : value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

/// A button that shows a spinner and ignores taps while [busy], or while an
/// async [onPressed] is still running.
class BusyButton extends StatefulWidget {
  const BusyButton({
    super.key,
    this.busy = false,
    required this.onPressed,
    required this.label,
    this.icon,
  });

  final bool busy;
  final FutureOr<void> Function()? onPressed;
  final String label;
  final IconData? icon;

  @override
  State<BusyButton> createState() => _BusyButtonState();
}

class _BusyButtonState extends State<BusyButton> {
  bool _running = false;

  Future<void> _tap() async {
    if (_running || widget.busy) return;
    final result = widget.onPressed?.call();
    if (result is! Future<void>) return;
    setState(() => _running = true);
    try {
      await result;
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.busy || _running;
    return FilledButton.icon(
      onPressed: busy || widget.onPressed == null ? null : _tap,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(widget.icon ?? Icons.check),
      label: Text(widget.label),
    );
  }
}
