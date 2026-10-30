import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_picker.dart';
import '../../widgets/states.dart';
import '../reports/report_widgets.dart' show tabularFigures;
import 'compliance_models.dart';
import 'compliance_repository.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// `2026-10` for [d].
String periodOf(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// The previous calendar month, the usual return period.
String previousMonth([DateTime? now]) {
  final n = now ?? DateTime.now();
  return periodOf(DateTime(n.year, n.month - 1));
}

/// `2026-10` → `Oct 2026`.
String periodLabel(String period) {
  final p = period.split('-');
  if (p.length != 2) return period;
  final m = int.tryParse(p[1]) ?? 1;
  return '${_months[(m - 1).clamp(0, 11)]} ${p[0]}';
}

/// `2026-27` for the financial year containing [d].
String fyOf(DateTime d) {
  final y = d.month >= 4 ? d.year : d.year - 1;
  return '$y-${((y + 1) % 100).toString().padLeft(2, '0')}';
}

/// Recent financial years, newest first.
List<String> recentFys([DateTime? now]) {
  final n = now ?? DateTime.now();
  final start = n.month >= 4 ? n.year : n.year - 1;
  return [
    for (var y = start; y > start - 5; y--)
      '$y-${((y + 1) % 100).toString().padLeft(2, '0')}',
  ];
}

/// Previous / next month arrows around a month label that opens a picker.
class MonthPicker extends StatelessWidget {
  const MonthPicker({super.key, required this.period, required this.onChanged});

  final String period;
  final ValueChanged<String> onChanged;

  DateTime get _date {
    final p = period.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]));
  }

  Future<void> _pick(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2017, 7),
      lastDate: DateTime(DateTime.now().year + 1, 12),
      helpText: 'Pick any day in the month',
    );
    if (picked != null) onChanged(periodOf(picked));
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Previous month',
        icon: const Icon(Icons.chevron_left),
        onPressed: () {
          final d = _date;
          onChanged(periodOf(DateTime(d.year, d.month - 1)));
        },
      ),
      OutlinedButton.icon(
        onPressed: () => _pick(context),
        icon: const Icon(Icons.calendar_month_outlined),
        label: Text(periodLabel(period)),
      ),
      IconButton(
        tooltip: 'Next month',
        icon: const Icon(Icons.chevron_right),
        onPressed: () {
          final d = _date;
          onChanged(periodOf(DateTime(d.year, d.month + 1)));
        },
      ),
    ],
  );
}

/// A single day picker button.
class DayButton extends StatelessWidget {
  const DayButton({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.clearable = false,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool clearable;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: () async {
      final now = DateTime.now();
      final d = await showDatePicker(
        context: context,
        initialDate: value ?? now,
        firstDate: DateTime(2017),
        lastDate: DateTime(now.year + 2),
      );
      if (d != null) onChanged(d);
    },
    icon: const Icon(Icons.event_outlined),
    label: Text(
      value == null ? label : '$label: ${formatDate(apiDate(value!))}',
    ),
  );
}

/// Copies [text] to the clipboard (the app's share route on every platform).
Future<void> shareText(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  showInfoSnackBar(context, '$what copied to the clipboard.');
}

/// Colour for a severity or status word.
Color statusColor(BuildContext context, String status) {
  final s = Theme.of(context).colorScheme;
  return switch (status) {
    'ok' ||
    'valid' ||
    'matched' ||
    'posted' ||
    'info' ||
    'accept' => Colors.green.shade700,
    'warn' || 'expiring' || 'mismatch' || 'pending' => Colors.orange.shade800,
    'due' ||
    'overdue' ||
    'expired' ||
    'cancelled' ||
    'reject' ||
    'missing_in_books' ||
    'missing_in_2b' => s.error,
    _ => s.onSurfaceVariant,
  };
}

class StatusPill extends StatelessWidget {
  const StatusPill(this.status, {super.key, this.label});

  final String status;
  final String? label;

  @override
  Widget build(BuildContext context) =>
      Pill(label ?? status, color: statusColor(context, status));
}

/// Banner listing [messages]; nothing when empty.
class WarningsBanner extends StatelessWidget {
  const WarningsBanner(
    this.messages, {
    super.key,
    this.title,
    this.error = false,
  });

  final List<String> messages;
  final String? title;
  final bool error;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty && title == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final fg = error ? scheme.onErrorContainer : scheme.onTertiaryContainer;
    return Card(
      color: error ? scheme.errorContainer : scheme.tertiaryContainer,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_outlined, color: fg),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title != null)
                    Text(
                      title!,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(color: fg),
                    ),
                  for (final m in messages)
                    Text(m, style: TextStyle(color: fg)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tax heads in a horizontally scrolling table, one row per entry.
class TaxTable extends StatelessWidget {
  const TaxTable({
    super.key,
    required this.rows,
    this.firstColumn = '',
    this.showTaxable = true,
  });

  final List<(String, Tax)> rows;
  final String firstColumn;
  final bool showTaxable;

  @override
  Widget build(BuildContext context) {
    DataCell n(double v) =>
        DataCell(Text(formatAmount(v), style: tabularFigures));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 40,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 52,
        columns: [
          DataColumn(label: Text(firstColumn)),
          if (showTaxable)
            const DataColumn(label: Text('Taxable'), numeric: true),
          const DataColumn(label: Text('IGST'), numeric: true),
          const DataColumn(label: Text('CGST'), numeric: true),
          const DataColumn(label: Text('SGST'), numeric: true),
        ],
        rows: [
          for (final (label, t) in rows)
            DataRow(
              cells: [
                DataCell(
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(label, overflow: TextOverflow.ellipsis),
                  ),
                ),
                if (showTaxable) n(t.taxable),
                n(t.igst),
                n(t.cgst),
                n(t.sgst),
              ],
            ),
        ],
      ),
    );
  }
}

/// A read-only picker field opening the account search.
Future<AccountOption?> pickAccount(
  BuildContext context,
  WidgetRef ref, {
  String title = 'Choose account',
  bool Function(AccountOption)? where,
}) async {
  List<AccountOption> all;
  try {
    all = await ref.read(accountOptionsProvider.future);
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
    return null;
  }
  if (!context.mounted) return null;
  final list = where == null ? all : all.where(where).toList();
  return showSearchPicker<AccountOption>(
    context: context,
    title: title,
    search: (q) async {
      final needle = q.trim().toLowerCase();
      return list
          .where(
            (a) => needle.isEmpty || a.label.toLowerCase().contains(needle),
          )
          .toList();
    },
    titleBuilder: (_, a) => Text(a.name),
    subtitleBuilder: (_, a) => Text(a.code),
  );
}

/// UTF-8 text of picked file bytes (BOM stripped).
String decodeBytes(List<int> bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  return text.startsWith('\uFEFF') ? text.substring(1) : text;
}

/// Lets the user pick a text file and returns its name and UTF-8 content,
/// or `null` when cancelled. Works on web (bytes, no path).
Future<({String name, String text})?> pickTextFile(
  List<String> extensions,
) async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (file == null) return null;
  return (name: file.name, text: decodeBytes(await file.readAsBytes()));
}
