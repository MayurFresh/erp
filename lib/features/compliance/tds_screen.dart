import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../reports/report_widgets.dart'
    show ReportSectionTitle, StatRow, StatTile, tabularFigures;
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';
import 'tax_perms.dart';

/// `/tds`: deductions, deposit summary and the quarterly statement.
class TdsScreen extends ConsumerStatefulWidget {
  const TdsScreen({super.key});

  @override
  ConsumerState<TdsScreen> createState() => _TdsScreenState();
}

class _TdsScreenState extends ConsumerState<TdsScreen> {
  String _fy = fyOf(DateTime.now());

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'TDS',
          subtitle: 'Tax deducted at source: deposit and file',
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Financial year',
              value: _fy,
              options: {for (final f in recentFys()) f: f},
              anyLabel: _fy,
              width: 180,
              onChanged: (v) => setState(() => _fy = v ?? _fy),
            ),
          ],
        ),
        const TabBar(
          tabs: [
            Tab(text: 'Deductions'),
            Tab(text: 'Summary'),
            Tab(text: 'Statement'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _DeductionsTab(key: ValueKey('d$_fy'), fy: _fy),
              _SummaryTab(fy: _fy),
              _StatementTab(fy: _fy),
            ],
          ),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------- Deductions

class _DeductionsTab extends ConsumerStatefulWidget {
  const _DeductionsTab({super.key, required this.fy});

  final String fy;

  @override
  ConsumerState<_DeductionsTab> createState() => _DeductionsTabState();
}

class _DeductionsTabState extends ConsumerState<_DeductionsTab> {
  late final PagedController<TdsDeduction> _c;
  int? _quarter;
  String _section = '';
  bool _pending = true;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _c = PagedController<TdsDeduction>(
      (offset, limit) => ref
          .read(complianceRepositoryProvider)
          .tdsDeductions(
            fy: widget.fy,
            quarter: _quarter,
            sectionCode: _section,
            notDeposited: _pending,
            offset: offset,
            limit: limit,
          ),
    )..refresh();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _reload() {
    _selected.clear();
    _c.refresh();
  }

  Future<void> _record() async {
    final rows = _c.items.where((d) => _selected.contains(d.id)).toList();
    final challan = await showDialog<TdsChallan>(
      context: context,
      builder: (_) => ChallanDialog(deductions: rows),
    );
    if (challan == null || !mounted) return;
    ref.read(complianceRevisionProvider.notifier).bump();
    ref.bump(const [DataKind.accounts]);
    context.go('/tds-challans/${challan.id}');
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.tdsManage);
    final selectedTotal = _c.items
        .where((d) => _selected.contains(d.id))
        .fold<double>(0, (a, d) => a + d.amount);
    return Column(
      children: [
        FilterBar(
          children: [
            FilterDropdown<int>(
              label: 'Quarter',
              value: _quarter,
              options: const {1: 'Q1', 2: 'Q2', 3: 'Q3', 4: 'Q4'},
              anyLabel: 'All quarters',
              width: 150,
              onChanged: (v) {
                _quarter = v;
                _reload();
              },
            ),
            SizedBox(
              width: 140,
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Section',
                  hintText: '194C',
                ),
                onSubmitted: (v) {
                  _section = v.trim().toUpperCase();
                  _reload();
                },
              ),
            ),
            FilterChip(
              label: const Text('Not deposited'),
              selected: _pending,
              onSelected: (v) {
                _pending = v;
                _reload();
              },
            ),
          ],
        ),
        if (manage && _selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_selected.length} selected · ${formatMoney(selectedTotal)}',
                  ),
                ),
                FilledButton.icon(
                  onPressed: _record,
                  icon: const Icon(Icons.account_balance_outlined),
                  label: const Text('Record challan'),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListenableBuilder(
            listenable: _c,
            builder: (context, _) {
              if (_c.items.isEmpty) {
                if (_c.loading || !_c.loaded) return const LoadingView();
                if (_c.error != null) {
                  return ErrorView(error: _c.error!, onRetry: _c.refresh);
                }
                return const EmptyView(
                  message: 'No TDS deductions match.',
                  icon: Icons.receipt_outlined,
                );
              }
              return RefreshIndicator(
                onRefresh: _c.refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  children: [
                    for (final d in _c.items) _row(d, manage),
                    if (_c.hasMore)
                      Center(
                        child: TextButton(
                          onPressed: _c.loadMore,
                          child: Text(
                            'Load more (${_c.items.length} of ${_c.total})',
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _row(TdsDeduction d, bool manage) {
    final selectable = manage && d.depositable;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: selectable
            ? Checkbox(
                value: _selected.contains(d.id),
                onChanged: (v) => setState(
                  () =>
                      v == true ? _selected.add(d.id) : _selected.remove(d.id),
                ),
              )
            : null,
        onTap: selectable
            ? () => setState(
                () => _selected.contains(d.id)
                    ? _selected.remove(d.id)
                    : _selected.add(d.id),
              )
            : null,
        title: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${d.partyName} · ${d.sectionCode}'),
            if (d.pan == null || d.pan!.isEmpty)
              const StatusPill('warn', label: 'No PAN'),
            if (d.challanNumber != null)
              ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(d.challanNumber!),
                onPressed: () => context.go('/tds-challans/${d.challanId}'),
              ),
          ],
        ),
        subtitle: Text(
          '${d.number} · ${formatDate(d.date)} · gross ${formatAmount(d.gross)} '
          '· ${formatPercent(d.rate)} on ${formatAmount(d.base)}',
        ),
        trailing: Text(
          formatAmount(d.amount),
          style: tabularFigures.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// Collects challan details for [deductions] and posts the challan.
class ChallanDialog extends ConsumerStatefulWidget {
  const ChallanDialog({super.key, required this.deductions});

  final List<TdsDeduction> deductions;

  @override
  ConsumerState<ChallanDialog> createState() => _ChallanDialogState();
}

class _ChallanDialogState extends ConsumerState<ChallanDialog> {
  final _form = GlobalKey<FormState>();
  final _bsr = TextEditingController();
  final _serial = TextEditingController();
  final _interest = TextEditingController();
  final _lateFee = TextEditingController();
  DateTime _date = DateTime.now();
  AccountOption? _account;
  bool _busy = false;
  String? _accountError;

  @override
  void dispose() {
    _bsr.dispose();
    _serial.dispose();
    _interest.dispose();
    _lateFee.dispose();
    super.dispose();
  }

  double get _tax => widget.deductions.fold(0, (a, d) => a + d.amount);
  double _num(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

  String? _digits(String? v, int n, String what) =>
      RegExp('^\\d{$n}\$').hasMatch((v ?? '').trim())
      ? null
      : '$what is $n digits';

  String? _money(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final n = double.tryParse(v.trim());
    return n == null || n < 0 ? 'Enter an amount' : null;
  }

  Future<void> _submit() async {
    final ok = _form.currentState!.validate();
    if (_account == null) setState(() => _accountError = 'Choose the account');
    if (!ok || _account == null) return;
    setState(() => _busy = true);
    try {
      final c = await ref.read(complianceRepositoryProvider).createChallan({
        'depositDate': apiDate(_date),
        'bsrCode': _bsr.text.trim(),
        'challanSerial': _serial.text.trim(),
        'paidFromAccountId': _account!.id,
        'deductionIds': [for (final d in widget.deductions) d.id],
        if (_num(_interest) > 0) 'interest': _num(_interest),
        if (_num(_lateFee) > 0) 'lateFee': _num(_lateFee),
      });
      if (mounted) Navigator.pop(context, c);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _tax + _num(_interest) + _num(_lateFee);
    return AlertDialog(
      title: const Text('Record TDS challan'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${widget.deductions.length} deductions · tax ${formatMoney(_tax)}',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2017),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                    );
                    if (d != null) setState(() => _date = d);
                  },
                  icon: const Icon(Icons.event_outlined),
                  label: Text('Deposit date: ${formatDate(apiDate(_date))}'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _bsr,
                  keyboardType: TextInputType.number,
                  maxLength: 7,
                  decoration: const InputDecoration(
                    labelText: 'BSR code (7 digits)',
                  ),
                  validator: (v) => _digits(v, 7, 'BSR code'),
                ),
                TextFormField(
                  controller: _serial,
                  keyboardType: TextInputType.number,
                  maxLength: 5,
                  decoration: const InputDecoration(
                    labelText: 'Challan serial (5 digits)',
                  ),
                  validator: (v) => _digits(v, 5, 'Challan serial'),
                ),
                PickerField(
                  label: 'Paid from (cash or bank)',
                  value: _account?.label,
                  errorText: _accountError,
                  onTap: () async {
                    final a = await pickAccount(
                      context,
                      ref,
                      title: 'Paid from',
                      where: (a) => a.subtype == 'bank' || a.subtype == 'cash',
                    );
                    if (a != null) {
                      setState(() {
                        _account = a;
                        _accountError = null;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _interest,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Interest (optional)',
                  ),
                  validator: _money,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _lateFee,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Late fee (optional)',
                  ),
                  validator: _money,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Text(
                  'Total paid ${formatMoney(total)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        BusyButton(busy: _busy, onPressed: _submit, label: 'Record challan'),
      ],
    );
  }
}

// ----------------------------------------------------------------- Summary

class _SummaryTab extends ConsumerWidget {
  const _SummaryTab({required this.fy});

  final String fy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(tdsSummaryProvider(fy));
    final challans = ref.watch(tdsChallansProvider(fy));
    return AsyncValueView<TdsSummary>(
      value: value,
      onRetry: () => ref.invalidate(tdsSummaryProvider(fy)),
      data: (s) {
        final pending = s.months.fold<double>(0, (a, m) => a + m.pending);
        final overdue = s.months
            .where((m) => m.overdue)
            .fold<double>(0, (a, m) => a + m.pending);
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            StatRow(
              children: [
                StatTile(
                  label: 'Deducted',
                  value: formatMoney(
                    s.months.fold<double>(0, (a, m) => a + m.deducted),
                  ),
                ),
                StatTile(
                  label: 'Deposited',
                  value: formatMoney(
                    s.months.fold<double>(0, (a, m) => a + m.deposited),
                  ),
                ),
                StatTile(label: 'Pending', value: formatMoney(pending)),
                StatTile(
                  label: 'Overdue',
                  value: formatMoney(overdue),
                  color: overdue > 0
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
              ],
            ),
            const ReportSectionTitle('Deposits by month'),
            for (final m in s.months)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  title: Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(periodLabel(m.month)),
                      if (m.overdue)
                        const StatusPill('overdue', label: 'Overdue')
                      else if (m.pending <= 0 && m.deducted > 0)
                        const StatusPill('ok', label: 'Deposited'),
                    ],
                  ),
                  subtitle: Text(
                    'Due ${formatDate(m.dueDate)} · deducted ${formatAmount(m.deducted)}'
                    ' · deposited ${formatAmount(m.deposited)}',
                  ),
                  trailing: Text(
                    formatAmount(m.pending),
                    style: tabularFigures.copyWith(
                      fontWeight: FontWeight.w700,
                      color: m.overdue
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                ),
              ),
            const ReportSectionTitle('Quarterly statements (Form 140)'),
            for (final q in s.quarters)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  title: Text('Q${q.quarter} · due ${formatDate(q.dueDate)}'),
                  subtitle: Text('${q.rows} deduction rows'),
                  trailing: Text(formatAmount(q.amount), style: tabularFigures),
                ),
              ),
            const ReportSectionTitle('Challans'),
            switch (challans) {
              AsyncValue(:final List<TdsChallan> value, hasValue: true) =>
                value.isEmpty
                    ? const Text('No challans recorded for this year.')
                    : Column(
                        children: [
                          for (final c in value)
                            Card(
                              margin: const EdgeInsets.only(bottom: 6),
                              child: ListTile(
                                onTap: () =>
                                    context.go('/tds-challans/${c.id}'),
                                title: Wrap(
                                  spacing: 8,
                                  children: [
                                    Text(c.number),
                                    StatusPill(c.status),
                                  ],
                                ),
                                subtitle: Text(
                                  '${formatDate(c.depositDate)} · BSR ${c.bsrCode} · serial ${c.challanSerial}',
                                ),
                                trailing: Text(
                                  formatAmount(c.total),
                                  style: tabularFigures,
                                ),
                              ),
                            ),
                        ],
                      ),
              AsyncValue(:final Object error, hasError: true) => Text('$error'),
              _ => const LinearProgressIndicator(),
            },
          ],
        );
      },
    );
  }
}

// --------------------------------------------------------------- Statement

class _StatementTab extends ConsumerStatefulWidget {
  const _StatementTab({required this.fy});

  final String fy;

  @override
  ConsumerState<_StatementTab> createState() => _StatementTabState();
}

class _StatementTabState extends ConsumerState<_StatementTab> {
  int _quarter = _currentQuarter();
  bool _busy = false;

  static int _currentQuarter() {
    final m = DateTime.now().month;
    return m >= 4 && m <= 6
        ? 1
        : m >= 7 && m <= 9
        ? 2
        : m >= 10
        ? 3
        : 4;
  }

  Future<void> _csv() async {
    setState(() => _busy = true);
    try {
      final text = await ref
          .read(complianceRepositoryProvider)
          .tdsStatementCsv(widget.fy, _quarter);
      if (mounted) await shareText(context, text, 'Statement CSV');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final key = (widget.fy, _quarter);
    final value = ref.watch(tdsStatementProvider(key));
    return Column(
      children: [
        FilterBar(
          children: [
            FilterDropdown<int>(
              label: 'Quarter',
              value: _quarter,
              options: const {1: 'Q1', 2: 'Q2', 3: 'Q3', 4: 'Q4'},
              anyLabel: 'Q$_quarter',
              width: 140,
              onChanged: (v) => setState(() => _quarter = v ?? _quarter),
            ),
            BusyButton(
              busy: _busy,
              onPressed: _csv,
              label: 'Copy CSV',
              icon: Icons.ios_share,
            ),
            OutlinedButton.icon(
              onPressed: () =>
                  context.go('/tds/file?fy=${widget.fy}&quarter=$_quarter'),
              icon: const Icon(Icons.fact_check_outlined),
              label: const Text('File return'),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<TdsStatement>(
            value: value,
            onRetry: () => ref.invalidate(tdsStatementProvider(key)),
            data: (s) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                WarningsBanner(
                  s.warnings,
                  title: s.warnings.isEmpty ? null : 'Check before filing',
                ),
                SectionCard(
                  title: 'Form ${s.form} · FY ${s.fy} · Q${s.quarter}',
                  child: Wrap(
                    spacing: 32,
                    runSpacing: 12,
                    children: [
                      LabeledValue('Deductor', s.deductorName),
                      LabeledValue('TAN', s.tan ?? ''),
                      LabeledValue('PAN', s.pan ?? ''),
                      LabeledValue('Challans', '${s.challans.length}'),
                      LabeledValue('Deduction rows', '${s.rows.length}'),
                    ],
                  ),
                ),
                const Text(
                  'The CSV is a working file for a TDS utility, not the '
                  'official FVU format.',
                ),
                if (s.rows.isNotEmpty) ...[
                  const ReportSectionTitle('Deductions'),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('PAN')),
                        DataColumn(label: Text('Party')),
                        DataColumn(label: Text('Section')),
                        DataColumn(label: Text('Date')),
                        DataColumn(label: Text('Base'), numeric: true),
                        DataColumn(label: Text('Rate'), numeric: true),
                        DataColumn(label: Text('Tax'), numeric: true),
                        DataColumn(label: Text('Challan')),
                      ],
                      rows: [
                        for (final r in s.rows)
                          DataRow(
                            cells: [
                              DataCell(Text('${r['pan'] ?? '—'}')),
                              DataCell(Text('${r['partyName'] ?? ''}')),
                              DataCell(Text('${r['sectionCode'] ?? ''}')),
                              DataCell(Text(formatDate(r['date']))),
                              DataCell(
                                Text(
                                  formatAmount(num.tryParse('${r['base']}')),
                                ),
                              ),
                              DataCell(
                                Text(
                                  formatPercent(num.tryParse('${r['rate']}')),
                                ),
                              ),
                              DataCell(
                                Text(
                                  formatAmount(num.tryParse('${r['amount']}')),
                                ),
                              ),
                              DataCell(Text('${r['challanSerial'] ?? '—'}')),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}
