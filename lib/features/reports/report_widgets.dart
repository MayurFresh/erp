import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'report_export.dart';
import 'report_models.dart';
import 'report_pdf.dart';
import 'report_period.dart';

/// Digits line up in columns.
const TextStyle tabularFigures = TextStyle(
  fontFeatures: [FontFeature.tabularFigures()],
);

// --------------------------------------------------------------- Page frame

/// Title, export actions, a wrapping row of period/filter [controls] and
/// the [body] filling the rest. Used by every report and the ledger.
class ReportPage extends StatelessWidget {
  const ReportPage({
    super.key,
    required this.title,
    required this.controls,
    required this.body,
    this.subtitle,
    this.export,
    this.extraActions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> controls;

  /// `null` while loading or on error: the export buttons are disabled.
  final ReportExport? export;
  final List<Widget> extraActions;
  final Widget body;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      PageHeader(
        title: title,
        subtitle: subtitle,
        actions: [...extraActions, ExportActions(export: export)],
      ),
      if (controls.isNotEmpty) FilterBar(children: controls),
      Expanded(child: body),
    ],
  );
}

/// Loading / error-with-retry / empty / content for a report, with the
/// content in a padded scrolling list.
class ReportBody<T> extends StatelessWidget {
  const ReportBody({
    super.key,
    required this.value,
    required this.builder,
    required this.onRetry,
    this.isEmpty,
    this.emptyMessage = 'Nothing to show for this period.',
    this.emptyIcon = Icons.insert_chart_outlined,
  });

  final AsyncValue<T> value;
  final List<Widget> Function(T data) builder;
  final VoidCallback onRetry;
  final bool Function(T data)? isEmpty;
  final String emptyMessage;
  final IconData emptyIcon;

  @override
  Widget build(BuildContext context) {
    return switch (value) {
      AsyncValue(:final T value, hasValue: true) =>
        isEmpty?.call(value) ?? false
            ? EmptyView(message: emptyMessage, icon: emptyIcon)
            : RefreshIndicator(
                onRefresh: () async => onRetry(),
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: builder(value),
                ),
              ),
      AsyncValue(:final Object error, hasError: true) => ErrorView(
        error: error,
        onRetry: onRetry,
      ),
      _ => const LoadingView(),
    };
  }
}

// ------------------------------------------------------------- Period pickers

/// Shows [value]; offers financial-year presets and a custom range.
class PeriodButton extends StatelessWidget {
  const PeriodButton({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final DateRange value;
  final ValueChanged<DateRange> onChanged;

  Future<void> _custom(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: financialYearEnd(now),
      initialDateRange: DateTimeRange(start: value.from, end: value.to),
      helpText: 'Choose the period',
    );
    if (picked != null) onChanged(DateRange(picked.start, picked.end));
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      for (final preset in RangePreset.values)
        MenuItemButton(
          onPressed: () => onChanged(preset.resolve()),
          child: Text(preset.label),
        ),
      const Divider(height: 1),
      MenuItemButton(
        leadingIcon: const Icon(Icons.edit_calendar_outlined),
        onPressed: () => _custom(context),
        child: const Text('Custom range…'),
      ),
    ],
    builder: (context, controller, _) => OutlinedButton.icon(
      onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      icon: const Icon(Icons.date_range_outlined),
      label: Text(value.label, overflow: TextOverflow.ellipsis),
    ),
  );
}

/// Shows "As of 21 Oct 2026"; offers quick dates and a date picker.
class AsOfButton extends StatelessWidget {
  const AsOfButton({super.key, required this.value, required this.onChanged});

  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2000),
      lastDate: financialYearEnd(now),
      helpText: 'As of',
    );
    if (picked != null) onChanged(dateOnly(picked));
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    menuChildren: [
      for (final preset in AsOfPreset.values)
        MenuItemButton(
          onPressed: () => onChanged(preset.resolve()),
          child: Text(preset.label),
        ),
      const Divider(height: 1),
      MenuItemButton(
        leadingIcon: const Icon(Icons.edit_calendar_outlined),
        onPressed: () => _pick(context),
        child: const Text('Pick a date…'),
      ),
    ],
    builder: (context, controller, _) => OutlinedButton.icon(
      onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      icon: const Icon(Icons.event_outlined),
      label: Text('As of ${formatDate(value)}'),
    ),
  );
}

// -------------------------------------------------------------------- Export

/// Copies [export] as CSV to the clipboard and confirms with a SnackBar.
Future<void> copyCsv(BuildContext context, ReportExport export) async {
  await Clipboard.setData(ClipboardData(text: export.toCsv()));
  if (!context.mounted) return;
  final rows = export.rows.length;
  showInfoSnackBar(
    context,
    'Copied $rows ${rows == 1 ? 'row' : 'rows'} as CSV — paste into a '
    'spreadsheet.',
  );
}

/// "Export CSV", "Download PDF" and "Print"; one "Export" menu on phones.
class ExportActions extends ConsumerWidget {
  const ExportActions({super.key, required this.export});

  final ReportExport? export;

  Future<void> _pdf(BuildContext context, WidgetRef ref, bool print) async {
    final e = export;
    if (e == null) return;
    try {
      final company = ref.read(sessionProvider).value?.company?.name;
      final bytes = await buildReportPdf(e, companyName: company);
      if (print) {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: e.fileName);
      } else {
        await Printing.sharePdf(bytes: bytes, filename: '${e.fileName}.pdf');
      }
    } catch (error) {
      if (context.mounted) showErrorSnackBar(context, error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = export;
    final enabled = e != null;
    void csv() => copyCsv(context, e!);
    if (MediaQuery.sizeOf(context).width < 600) {
      return MenuAnchor(
        menuChildren: [
          MenuItemButton(
            leadingIcon: const Icon(Icons.copy_all_outlined),
            onPressed: enabled ? csv : null,
            child: const Text('Export CSV (copy)'),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: enabled ? () => _pdf(context, ref, false) : null,
            child: const Text('Download PDF'),
          ),
          MenuItemButton(
            leadingIcon: const Icon(Icons.print_outlined),
            onPressed: enabled ? () => _pdf(context, ref, true) : null,
            child: const Text('Print'),
          ),
        ],
        builder: (context, controller, _) => FilledButton.tonalIcon(
          onPressed: enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
          icon: const Icon(Icons.ios_share),
          label: const Text('Export'),
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          onPressed: enabled ? csv : null,
          icon: const Icon(Icons.copy_all_outlined),
          label: const Text('Export CSV'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? () => _pdf(context, ref, false) : null,
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: const Text('Download PDF'),
        ),
        OutlinedButton.icon(
          onPressed: enabled ? () => _pdf(context, ref, true) : null,
          icon: const Icon(Icons.print_outlined),
          label: const Text('Print'),
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------- Tables

class ReportColumn<T> {
  const ReportColumn(
    this.label,
    this.value, {
    this.numeric = false,
    this.flex = false,
    this.maxWidth,
  });

  final String label;
  final String Function(T row) value;

  /// Right-aligned with tabular figures.
  final bool numeric;

  /// Takes the spare width when the table is narrower than its card.
  final bool flex;

  /// Longer text is ellipsized on one line.
  final double? maxWidth;
}

/// A report table inside a card. It scrolls sideways when it is wider than
/// the card; below [cardBreakpoint] it switches to [cardBuilder] cards when
/// one is given. [totals] (aligned with [columns]) is a bold last row.
class ReportTable<T> extends StatelessWidget {
  const ReportTable({
    super.key,
    required this.columns,
    required this.rows,
    this.totals,
    this.onTap,
    this.dimmed,
    this.cardBuilder,
    this.totalsCard,
    this.cardBreakpoint = 600,
    this.emptyText = 'No rows.',
  });

  final List<ReportColumn<T>> columns;
  final List<T> rows;
  final List<String>? totals;
  final void Function(T row)? onTap;

  /// Rows drawn faded (e.g. cancelled documents).
  final bool Function(T row)? dimmed;
  final Widget Function(BuildContext context, T row)? cardBuilder;

  /// Shown after the cards in card mode.
  final Widget? totalsCard;
  final double cardBreakpoint;
  final String emptyText;

  Widget _cell(BuildContext context, String text, ReportColumn<T> column,
      {TextStyle? style}) {
    final child = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: column.numeric ? tabularFigures.merge(style) : style,
    );
    final max = column.maxWidth;
    return max == null
        ? child
        : ConstrainedBox(
            constraints: BoxConstraints(maxWidth: max),
            child: Tooltip(message: text, child: child),
          );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cards = cardBuilder;
        if (cards != null && constraints.maxWidth < cardBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(emptyText),
                ),
              for (final row in rows) ...[
                cards(context, row),
                const SizedBox(height: 8),
              ],
              ?totalsCard,
            ],
          );
        }
        final bold = const TextStyle(fontWeight: FontWeight.w700);
        final faded = TextStyle(color: theme.colorScheme.outline);
        final tap = onTap;
        return Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                showCheckboxColumn: false,
                columnSpacing: 20,
                horizontalMargin: 12,
                headingRowHeight: 44,
                dataRowMinHeight: 40,
                dataRowMaxHeight: 48,
                columns: [
                  for (final c in columns)
                    DataColumn(
                      label: Text(c.label),
                      numeric: c.numeric,
                      columnWidth: c.flex
                          ? const IntrinsicColumnWidth(flex: 1)
                          : null,
                    ),
                ],
                rows: [
                  for (final row in rows)
                    DataRow(
                      onSelectChanged: tap == null ? null : (_) => tap(row),
                      cells: [
                        for (final c in columns)
                          DataCell(
                            _cell(
                              context,
                              c.value(row),
                              c,
                              style: (dimmed?.call(row) ?? false)
                                  ? faded
                                  : null,
                            ),
                          ),
                      ],
                    ),
                  if (totals != null)
                    DataRow(
                      color: WidgetStatePropertyAll(
                        theme.colorScheme.surfaceContainerHighest,
                      ),
                      cells: [
                        for (var i = 0; i < columns.length; i++)
                          DataCell(
                            _cell(
                              context,
                              i < totals!.length ? totals![i] : '',
                              columns[i],
                              style: bold,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A phone card for one report row: title and trailing amount on top, then
/// label/value pairs.
class ReportRowCard extends StatelessWidget {
  const ReportRowCard({
    super.key,
    required this.title,
    required this.trailing,
    this.subtitle,
    this.pairs = const [],
    this.onTap,
    this.dimmed = false,
    this.highlight = false,
  });

  final String title;
  final String? subtitle;
  final String trailing;
  final List<(String, String)> pairs;
  final VoidCallback? onTap;
  final bool dimmed;

  /// Totals card styling.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final color = dimmed ? theme.colorScheme.outline : null;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: highlight ? theme.colorScheme.surfaceContainerHighest : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(color: color),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    trailing,
                    style: theme.textTheme.titleSmall
                        ?.merge(tabularFigures)
                        .copyWith(fontWeight: FontWeight.w700, color: color),
                  ),
                ],
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  style: muted,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              if (pairs.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 16,
                  runSpacing: 2,
                  children: [
                    for (final (label, value) in pairs)
                      Text('$label $value', style: muted?.merge(tabularFigures)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------- Statement blocks

/// One line of a financial statement: label left, amount right.
class StatementLine extends StatelessWidget {
  const StatementLine(
    this.label,
    this.amount, {
    super.key,
    this.code,
    this.bold = false,
    this.large = false,
    this.color,
    this.amountText,
  });

  final String label;
  final String? code;
  final double amount;
  final bool bold;
  final bool large;
  final Color? color;

  /// Replaces the formatted [amount].
  final String? amountText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = large ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium;
    final style = base?.copyWith(
      fontWeight: bold || large ? FontWeight.w700 : null,
      color: color,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (code != null && code!.isNotEmpty) ...[
            SizedBox(
              width: 48,
              child: Text(
                code!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 12),
          Text(
            amountText ?? formatMoney(amount),
            style: style?.merge(tabularFigures),
            textAlign: TextAlign.right,
          ),
        ],
      ),
    );
  }
}

/// A titled statement section: its rows, then a bold total.
class StatementBlock extends StatelessWidget {
  const StatementBlock({
    super.key,
    required this.title,
    required this.section,
    this.totalLabel,
    this.emptyText = 'None',
  });

  final String title;
  final StatementSection section;
  final String? totalLabel;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        if (section.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              emptyText,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final row in section.rows)
          StatementLine(row.name, row.amount, code: row.code),
        const Divider(height: 12),
        StatementLine(totalLabel ?? 'Total $title', section.total, bold: true),
      ],
    );
  }
}

// ------------------------------------------------------------- Small pieces

/// Green "Balanced" or a red "Difference ₹X" pill.
class BalanceCheck extends StatelessWidget {
  const BalanceCheck({
    super.key,
    required this.difference,
    this.balancedLabel = 'Balanced',
  });

  final double difference;
  final String balancedLabel;

  @override
  Widget build(BuildContext context) {
    final ok = isZeroAmount(difference);
    final scheme = Theme.of(context).colorScheme;
    final color = ok ? Colors.green.shade700 : scheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(ok ? Icons.check_circle : Icons.error_outline, color: color, size: 18),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            ok ? balancedLabel : 'Difference ${formatMoney(difference.abs())}',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

/// A label over a big number, for report summaries.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.color,
    this.width = 180,
  });

  final String label;
  final String value;
  final String? caption;
  final Color? color;
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: 140, maxWidth: width),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: theme.textTheme.titleMedium
                      ?.merge(tabularFigures)
                      .copyWith(fontWeight: FontWeight.w700, color: color),
                ),
              ),
              if (caption != null)
                Text(
                  caption!,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A wrapping row of [StatTile]s.
class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Wrap(spacing: 8, runSpacing: 8, children: children),
  );
}

/// A heading between report sections.
class ReportSectionTitle extends StatelessWidget {
  const ReportSectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 4,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        ?trailing,
      ],
    ),
  );
}
