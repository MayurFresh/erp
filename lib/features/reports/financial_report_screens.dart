import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../accounting/accounting_models.dart' show accountTypeLabel;
import 'report_exports.dart';
import 'report_models.dart';
import 'report_period.dart';
import 'report_widgets.dart';
import 'reports_repository.dart';

/// `/financials/trial-balance`.
class TrialBalanceScreen extends ConsumerStatefulWidget {
  const TrialBalanceScreen({super.key});

  @override
  ConsumerState<TrialBalanceScreen> createState() => _TrialBalanceState();
}

class _TrialBalanceState extends ConsumerState<TrialBalanceScreen> {
  DateTime _asOf = dateOnly(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final key = apiDate(_asOf);
    final value = ref.watch(trialBalanceProvider(key));
    return ReportPage(
      title: 'Trial balance',
      subtitle: 'Accounts with a balance, debit and credit',
      export: value.value == null ? null : trialBalanceExport(value.value!),
      controls: [
        AsOfButton(value: _asOf, onChanged: (d) => setState(() => _asOf = d)),
      ],
      body: ReportBody<TrialBalance>(
        value: value,
        onRetry: () => ref.invalidate(trialBalanceProvider(key)),
        isEmpty: (tb) => tb.rows.isEmpty,
        emptyMessage: 'No balances as of ${formatDate(_asOf)}.',
        builder: (tb) => [
          StatRow(
            children: [
              StatTile(label: 'Total debit', value: formatMoney(tb.totalDebit)),
              StatTile(
                label: 'Total credit',
                value: formatMoney(tb.totalCredit),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: BalanceCheck(
              difference: tb.difference,
              balancedLabel: 'Debits equal credits',
            ),
          ),
          ReportTable<TrialBalanceRow>(
            rows: tb.rows,
            onTap: (r) => context.go('/accounts/${r.accountId}'),
            // Phones: one card per account with its Dr/Cr balance.
            cardBuilder: (context, r) => ReportRowCard(
              title: r.name,
              subtitle: '${r.code} · ${accountTypeLabel(r.type)}',
              trailing: r.debit > 0
                  ? '${formatMoney(r.debit)} Dr'
                  : '${formatMoney(r.credit)} Cr',
              onTap: () => context.go('/accounts/${r.accountId}'),
            ),
            totalsCard: ReportRowCard(
              title: 'Total',
              trailing: '',
              highlight: true,
              pairs: [
                ('Debit', formatMoney(tb.totalDebit)),
                ('Credit', formatMoney(tb.totalCredit)),
              ],
            ),
            columns: [
              ReportColumn('Code', (r) => r.code),
              ReportColumn('Account', (r) => r.name, flex: true, maxWidth: 280),
              ReportColumn('Type', (r) => accountTypeLabel(r.type)),
              ReportColumn(
                'Debit',
                (r) => formatOptionalMoney(r.debit),
                numeric: true,
              ),
              ReportColumn(
                'Credit',
                (r) => formatOptionalMoney(r.credit),
                numeric: true,
              ),
            ],
            totals: [
              '',
              'Total',
              '',
              formatMoney(tb.totalDebit),
              formatMoney(tb.totalCredit),
            ],
          ),
        ],
      ),
    );
  }
}

/// `/financials/profit-loss`.
class ProfitLossScreen extends ConsumerStatefulWidget {
  const ProfitLossScreen({super.key});

  @override
  ConsumerState<ProfitLossScreen> createState() => _ProfitLossState();
}

class _ProfitLossState extends ConsumerState<ProfitLossScreen> {
  DateRange _range = DateRange.fyToDate();

  @override
  Widget build(BuildContext context) {
    final key = (from: _range.apiFrom, to: _range.apiTo, locationId: null);
    final value = ref.watch(profitLossProvider(key));
    return ReportPage(
      title: 'Profit & loss',
      subtitle: _range.label,
      export: value.value == null
          ? null
          : profitLossExport(value.value!, period: _range.label),
      controls: [
        PeriodButton(
          value: _range,
          onChanged: (r) => setState(() => _range = r),
        ),
      ],
      body: ReportBody<ProfitLoss>(
        value: value,
        onRetry: () => ref.invalidate(profitLossProvider(key)),
        isEmpty: (pl) => pl.isEmpty,
        emptyMessage: 'No income or expenses in this period.',
        builder: (pl) {
          final loss = pl.netProfit < 0;
          final resultColor = loss
              ? Theme.of(context).colorScheme.error
              : Colors.green.shade700;
          return [
            StatRow(
              children: [
                StatTile(
                  label: 'Revenue',
                  value: formatMoney(pl.revenue.total),
                ),
                StatTile(
                  label: 'Gross profit',
                  value: formatMoney(pl.grossProfit),
                ),
                StatTile(
                  label: loss ? 'Net loss' : 'Net profit',
                  value: formatMoney(pl.netProfit.abs()),
                  color: resultColor,
                ),
              ],
            ),
            _StatementCard(
              children: [
                StatementBlock(
                  title: 'Revenue',
                  section: pl.revenue,
                  totalLabel: 'Net revenue',
                ),
                const SizedBox(height: 16),
                StatementBlock(title: 'Cost of goods sold', section: pl.cogs),
                const Divider(height: 24, thickness: 2),
                StatementLine('Gross profit', pl.grossProfit, large: true),
                const SizedBox(height: 16),
                StatementBlock(title: 'Other income', section: pl.otherIncome),
                const SizedBox(height: 16),
                StatementBlock(title: 'Expenses', section: pl.expenses),
                const Divider(height: 24, thickness: 2),
                StatementLine(
                  loss ? 'Net loss' : 'Net profit',
                  pl.netProfit,
                  large: true,
                  color: resultColor,
                ),
              ],
            ),
          ];
        },
      ),
    );
  }
}

/// `/financials/balance-sheet`: assets beside liabilities and equity, with
/// both totals shown together so a mismatch is obvious.
class BalanceSheetScreen extends ConsumerStatefulWidget {
  const BalanceSheetScreen({super.key});

  @override
  ConsumerState<BalanceSheetScreen> createState() => _BalanceSheetState();
}

class _BalanceSheetState extends ConsumerState<BalanceSheetScreen> {
  DateTime _asOf = dateOnly(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final key = apiDate(_asOf);
    final value = ref.watch(balanceSheetProvider(key));
    return ReportPage(
      title: 'Balance sheet',
      subtitle: 'As of ${formatDate(_asOf)}',
      export: value.value == null ? null : balanceSheetExport(value.value!),
      controls: [
        AsOfButton(value: _asOf, onChanged: (d) => setState(() => _asOf = d)),
      ],
      body: ReportBody<BalanceSheet>(
        value: value,
        onRetry: () => ref.invalidate(balanceSheetProvider(key)),
        isEmpty: (bs) => bs.isEmpty,
        emptyMessage: 'Nothing posted as of ${formatDate(_asOf)}.',
        builder: (bs) {
          final assets = _StatementCard(
            children: [
              StatementBlock(title: 'Assets', section: bs.assets),
              const Divider(height: 24, thickness: 2),
              StatementLine('Total assets', bs.totalAssets, large: true),
            ],
          );
          final claims = _StatementCard(
            children: [
              StatementBlock(title: 'Liabilities', section: bs.liabilities),
              const SizedBox(height: 16),
              StatementBlock(title: 'Equity', section: bs.equity),
              const Divider(height: 24, thickness: 2),
              StatementLine(
                'Total liabilities & equity',
                bs.totalLiabilitiesAndEquity,
                large: true,
              ),
            ],
          );
          return [
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 24,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    LabeledValue('Total assets', formatMoney(bs.totalAssets)),
                    LabeledValue(
                      'Liabilities & equity',
                      formatMoney(bs.totalLiabilitiesAndEquity),
                    ),
                    BalanceCheck(
                      difference: bs.difference,
                      balancedLabel:
                          'Balanced — assets equal liabilities '
                          '+ equity',
                    ),
                  ],
                ),
              ),
            ),
            FormRow(breakpoint: 840, children: [assets, claims]),
          ];
        },
      ),
    );
  }
}

class _StatementCard extends StatelessWidget {
  const _StatementCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}
