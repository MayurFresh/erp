import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../reports/report_period.dart';
import '../reports/report_widgets.dart';
import 'finance_exports.dart';
import 'finance_models.dart';
import 'finance_repository.dart';

/// Period, compare switch and the mapping shortcut shared by cash flow and ratios.
class CompareSwitch extends StatelessWidget {
  const CompareSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Switch(value: value, onChanged: onChanged),
        const SizedBox(width: 4),
        const Flexible(child: Text('Compare with last year')),
      ],
    ),
  );
}

/// `/cash-flow`: the indirect-method statement with a reconciliation check.
class CashFlowScreen extends ConsumerStatefulWidget {
  const CashFlowScreen({super.key});

  @override
  ConsumerState<CashFlowScreen> createState() => _CashFlowState();
}

class _CashFlowState extends ConsumerState<CashFlowScreen> {
  DateRange _range = DateRange.fyToDate();
  bool _compare = false;

  @override
  Widget build(BuildContext context) {
    final key = (from: _range.apiFrom, to: _range.apiTo, compare: _compare);
    final value = ref.watch(cashFlowProvider(key));
    final canMap = ref.watch(permissionsProvider).can(Perm.finreportsManage);
    return ReportPage(
      title: 'Cash flow',
      subtitle:
          'Indirect method: profit adjusted to the change in cash and bank',
      export: value.value == null ? null : cashFlowExport(value.value!),
      extraActions: [
        if (canMap)
          TextButton.icon(
            onPressed: () => context.go('/cash-flow/mapping'),
            icon: const Icon(Icons.tune_outlined),
            label: const Text('Account mapping'),
          ),
      ],
      controls: [
        PeriodButton(
          value: _range,
          onChanged: (r) => setState(() => _range = r),
        ),
        CompareSwitch(
          value: _compare,
          onChanged: (v) => setState(() => _compare = v),
        ),
      ],
      body: ReportBody<CashFlowReport>(
        value: value,
        onRetry: () => ref.invalidate(cashFlowProvider(key)),
        builder: (r) => cashFlowBlocks(r),
      ),
    );
  }
}

/// The statement as widgets; public so tests can pump it without a network.
List<Widget> cashFlowBlocks(CashFlowReport r) {
  final c = r.current;
  return [
    StatRow(
      children: [
        StatTile(
          label: 'Opening cash and bank',
          value: formatMoney(c.openingCash),
        ),
        StatTile(
          label: 'Closing cash and bank',
          value: formatMoney(c.closingCash),
        ),
      ],
    ),
    for (final s in c.sections) _SectionCard(section: s, report: r),
    _CheckCard(report: r),
  ];
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section, required this.report});
  final CfSection section;
  final CashFlowReport report;

  @override
  Widget build(BuildContext context) {
    final prev = report.previous;
    final prevTotal = prev?.section(section.key)?.total ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SectionCard(
        title: section.title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final line in section.lines)
              _LineTile(
                line: line,
                previous: report.previousLine(section.key, line.key),
              ),
            const Divider(height: 16),
            _AmountRow(
              label: 'Net cash from ${section.key} activities',
              amount: section.total,
              previous: prev == null ? null : prevTotal,
              bold: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.amount,
    this.previous,
    this.bold = false,
  });
  final String label;
  final double amount;
  final double? previous;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontWeight: bold ? FontWeight.w700 : null);
    final money = style?.merge(tabularFigures);
    final small = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(label, style: style)),
              const SizedBox(width: 12),
              Text(formatMoney(amount), style: money),
            ],
          ),
          if (previous != null)
            Text('Last year ${formatMoney(previous)}', style: small),
        ],
      ),
    );
  }
}

/// One statement line; tapping opens the accounts behind it.
class _LineTile extends StatelessWidget {
  const _LineTile({required this.line, this.previous});
  final CfLine line;
  final double? previous;

  @override
  Widget build(BuildContext context) {
    if (line.accounts.length <= 1 && line.group != 'working_capital') {
      return _AmountRow(
        label: line.label,
        amount: line.amount,
        previous: previous,
      );
    }
    // Same text sizes and row height as the plain lines, plus a chevron that shows it opens.
    final text = Theme.of(context).textTheme;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 12),
        dense: true,
        visualDensity: VisualDensity.compact,
        minTileHeight: 32,
        title: Text(line.label, style: text.bodyMedium),
        subtitle: previous == null
            ? null
            : Text(
                'Last year ${formatMoney(previous)}',
                style: text.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatMoney(line.amount),
              style: text.bodyMedium?.merge(tabularFigures),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 18),
          ],
        ),
        children: [
          for (final a in line.accounts)
            StatementLine(a.name, a.amount, code: a.code),
        ],
      ),
    );
  }
}

class _CheckCard extends StatelessWidget {
  const _CheckCard({required this.report});
  final CashFlowReport report;

  @override
  Widget build(BuildContext context) {
    final c = report.current;
    return SectionCard(
      title: 'Check against cash and bank balances',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatementLine('Change in cash and bank', c.netChange),
          StatementLine('Operating + investing + financing', c.computedChange),
          const SizedBox(height: 4),
          BalanceCheck(
            difference: c.difference,
            balancedLabel: 'Reconciles to the change in cash and bank',
          ),
        ],
      ),
    );
  }
}

/// `/cash-flow/mapping`: which section each balance sheet account falls in.
class CashFlowMappingScreen extends ConsumerWidget {
  const CashFlowMappingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(cfMappingProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Cash flow mapping',
          subtitle:
              'Choose where an account goes when the default does not fit, '
              'for example a loan named something else.',
        ),
        Expanded(
          child: ReportBody<List<CfMappingRow>>(
            value: value,
            onRetry: () => ref.invalidate(cfMappingProvider),
            builder: (rows) => [for (final r in rows) _MappingTile(row: r)],
          ),
        ),
      ],
    );
  }
}

class _MappingTile extends ConsumerWidget {
  const _MappingTile({required this.row});
  final CfMappingRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auto =
        'Default: ${cfCategoryLabels[row.defaultCategory] ?? row.defaultCategory}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${row.code}  ${row.name}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<String?>(
            initialValue: row.category,
            isExpanded: true,
            decoration: InputDecoration(helperText: auto),
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text('Use the default'),
              ),
              for (final e in cfCategoryLabels.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) async {
              try {
                await ref
                    .read(financeRepositoryProvider)
                    .setMapping(row.accountId, v);
                ref.read(financeRevisionProvider.notifier).bump();
              } catch (e) {
                if (context.mounted) showErrorSnackBar(context, e);
              }
            },
          ),
        ],
      ),
    );
  }
}
