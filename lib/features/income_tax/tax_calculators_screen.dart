import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_widgets.dart' show recentFys;
import '../reports/report_widgets.dart'
    show ReportSectionTitle, StatRow, StatTile, tabularFigures;
import 'it_models.dart';
import 'it_repository.dart';
import 'it_widgets.dart';

/// `/tax-calculators`: regime comparison, presumptive scheme, advance tax.
class TaxCalculatorsScreen extends StatelessWidget {
  const TaxCalculatorsScreen({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    initialIndex: initialTab,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Tax calculators',
          subtitle: 'Estimates only. Rates are marked unverified until checked',
        ),
        const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: 'Old vs new regime'),
            Tab(text: 'Presumptive'),
            Tab(text: 'Advance tax'),
          ],
        ),
        const Expanded(
          child: TabBarView(
            children: [RegimeTab(), PresumptiveTab(), AdvanceTaxTab()],
          ),
        ),
      ],
    ),
  );
}

double? _num(TextEditingController c) =>
    c.text.trim().isEmpty ? null : parseIndianNumber(c.text);

Widget _money(TextEditingController c, String label, {bool required = false}) =>
    TextFormField(
      controller: c,
      keyboardType: decimalKeyboard,
      inputFormatters: [moneyInput()],
      decoration: InputDecoration(labelText: label, prefixText: '₹ '),
      validator: (v) =>
          validateMoney(v, isRequired: required, label: label, min: 0),
    );

/// Width-limited field so rows wrap on phones.
Widget _w(Widget child) => ConstrainedBox(
  constraints: const BoxConstraints(maxWidth: 260, minWidth: 140),
  child: child,
);

class _TaxYearDropdown extends StatelessWidget {
  const _TaxYearDropdown({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: value,
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Tax year'),
    items: [
      for (final f in recentFys()) DropdownMenuItem(value: f, child: Text(f)),
    ],
    onChanged: (v) => onChanged(v ?? value),
  );
}

// ----------------------------------------------------------------- regime

class RegimeTab extends ConsumerStatefulWidget {
  const RegimeTab({super.key});

  @override
  ConsumerState<RegimeTab> createState() => _RegimeTabState();
}

class _RegimeTabState extends ConsumerState<RegimeTab> {
  final _form = GlobalKey<FormState>();
  final _salary = TextEditingController();
  final _business = TextEditingController();
  final _other = TextEditingController();
  final _s80c = TextEditingController();
  final _s80d = TextEditingController();
  final _home = TextEditingController();
  final _ded = TextEditingController();
  String _taxYear = recentFys().first;
  String _age = 'below60';
  RegimeResult? _result;

  @override
  void dispose() {
    for (final c in [_salary, _business, _other, _s80c, _s80d, _home, _ded]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _calc() async {
    if (!_form.currentState!.validate()) return;
    final deductions = <String, double>{
      if (_num(_s80c) != null) 's80c': _num(_s80c)!,
      if (_num(_s80d) != null) 's80d': _num(_s80d)!,
      if (_num(_home) != null) 'homeLoanInterest': _num(_home)!,
      if (_num(_ded) != null) 'other': _num(_ded)!,
    };
    try {
      final r = await ref.read(incomeTaxRepositoryProvider).regime({
        'taxYear': _taxYear,
        'age': _age,
        if (_num(_salary) != null) 'salary': _num(_salary),
        if (_num(_business) != null) 'business': _num(_business),
        if (_num(_other) != null) 'otherIncome': _num(_other),
        if (deductions.isNotEmpty) 'deductions': deductions,
      });
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Form(
          key: _form,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _w(
                _TaxYearDropdown(
                  value: _taxYear,
                  onChanged: (v) => setState(() => _taxYear = v),
                ),
              ),
              _w(
                DropdownButtonFormField<String>(
                  initialValue: _age,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Age'),
                  items: const [
                    DropdownMenuItem(value: 'below60', child: Text('Below 60')),
                    DropdownMenuItem(value: '60to80', child: Text('60 to 80')),
                    DropdownMenuItem(value: 'above80', child: Text('Above 80')),
                  ],
                  onChanged: (v) => setState(() => _age = v ?? _age),
                ),
              ),
              _w(_money(_salary, 'Salary')),
              _w(_money(_business, 'Business / profession income')),
              _w(_money(_other, 'Other income')),
              _w(_money(_s80c, '80C (old regime)')),
              _w(_money(_s80d, '80D (old regime)')),
              _w(_money(_home, 'Home loan interest (old)')),
              _w(_money(_ded, 'Other deductions (old)')),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: BusyButton(onPressed: _calc, label: 'Compare'),
        ),
        if (r != null) ...[
          const SizedBox(height: 16),
          UnverifiedNote(r.unverified),
          StatRow(
            children: [
              StatTile(
                label: 'Better regime',
                value: r.better == 'new' ? 'New' : 'Old',
              ),
              StatTile(label: 'You save', value: formatMoney(r.saving)),
            ],
          ),
          _CalcCard(
            title: 'New regime',
            calc: r.newRegime,
            best: r.better == 'new',
          ),
          _CalcCard(
            title: 'Old regime',
            calc: r.oldRegime,
            best: r.better == 'old',
          ),
        ],
      ],
    );
  }
}

class _CalcCard extends StatelessWidget {
  const _CalcCard({required this.title, required this.calc, this.best = false});

  final String title;
  final TaxCalc calc;
  final bool best;

  @override
  Widget build(BuildContext context) {
    Widget row(String l, double v, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(l)),
          Text(
            formatMoney(v),
            style: tabularFigures.copyWith(
              fontWeight: bold ? FontWeight.w700 : null,
            ),
          ),
        ],
      ),
    );
    return SectionCard(
      title: best ? '$title (lower tax)' : title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row('Taxable income', calc.taxable),
          for (final s in calc.slabs)
            if (s.tax != 0 || s.rate != 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${formatAmount(s.from)} to ${s.to == null ? 'above' : formatAmount(s.to)} at ${s.rate.toStringAsFixed(s.rate % 1 == 0 ? 0 : 1)}%',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Text(formatMoney(s.tax), style: tabularFigures),
                  ],
                ),
              ),
          row('Tax before rebate', calc.baseTax),
          row('Rebate', calc.rebate),
          row('Surcharge', calc.surcharge),
          row('Cess', calc.cess),
          const Divider(),
          row('Total tax', calc.total, bold: true),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- presumptive

class PresumptiveTab extends ConsumerStatefulWidget {
  const PresumptiveTab({super.key});

  @override
  ConsumerState<PresumptiveTab> createState() => _PresumptiveTabState();
}

class _PresumptiveTabState extends ConsumerState<PresumptiveTab> {
  final _form = GlobalKey<FormState>();
  final _digital = TextEditingController();
  final _cash = TextEditingController();
  final _declared = TextEditingController();
  String _taxYear = recentFys().first;
  String _kind = 'business';
  PresumptiveResult? _result;

  @override
  void dispose() {
    _digital.dispose();
    _cash.dispose();
    _declared.dispose();
    super.dispose();
  }

  Future<void> _calc() async {
    if (!_form.currentState!.validate()) return;
    try {
      final r = await ref.read(incomeTaxRepositoryProvider).presumptive({
        'taxYear': _taxYear,
        'kind': _kind,
        'digitalReceipts': _num(_digital) ?? 0,
        'cashReceipts': _num(_cash) ?? 0,
        if (_num(_declared) != null) 'declaredProfit': _num(_declared),
      });
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Form(
          key: _form,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _w(
                _TaxYearDropdown(
                  value: _taxYear,
                  onChanged: (v) => setState(() => _taxYear = v),
                ),
              ),
              _w(
                DropdownButtonFormField<String>(
                  initialValue: _kind,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Kind'),
                  items: const [
                    DropdownMenuItem(
                      value: 'business',
                      child: Text('Business (44AD)'),
                    ),
                    DropdownMenuItem(
                      value: 'profession',
                      child: Text('Profession (44ADA)'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _kind = v ?? _kind),
                ),
              ),
              _w(_money(_digital, 'Digital receipts', required: true)),
              _w(_money(_cash, 'Cash receipts', required: true)),
              _w(_money(_declared, 'Declared profit (optional)')),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: BusyButton(onPressed: _calc, label: 'Check'),
        ),
        if (r != null) ...[
          const SizedBox(height: 16),
          UnverifiedNote(r.unverified),
          StatRow(
            children: [
              StatTile(label: 'Eligible', value: r.eligible ? 'Yes' : 'No'),
              StatTile(label: 'Receipts limit', value: formatMoney(r.limit)),
              StatTile(
                label: 'Deemed income',
                value: formatMoney(r.deemedIncome),
              ),
            ],
          ),
          if (r.declaredBelowDeemed)
            const Text('Your declared profit is below the deemed income.'),
          if (r.auditRisk != null) ...[
            const SizedBox(height: 8),
            Text(
              r.auditRisk!,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 8),
          for (final n in r.notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $n'),
            ),
        ],
      ],
    );
  }
}

// ------------------------------------------------------------- advance tax

class AdvanceTaxTab extends ConsumerStatefulWidget {
  const AdvanceTaxTab({super.key});

  @override
  ConsumerState<AdvanceTaxTab> createState() => _AdvanceTaxTabState();
}

class _AdvanceTaxTabState extends ConsumerState<AdvanceTaxTab> {
  final _form = GlobalKey<FormState>();
  final _income = TextEditingController();
  String _taxYear = recentFys().first;
  String _regime = 'new';
  bool _presumptive = false;
  AdvanceTax? _result;

  @override
  void dispose() {
    _income.dispose();
    super.dispose();
  }

  Future<void> _calc() async {
    if (!_form.currentState!.validate()) return;
    try {
      final r = await ref
          .read(incomeTaxRepositoryProvider)
          .advanceTax(
            taxYear: _taxYear,
            estimatedIncome: _num(_income),
            regime: _regime,
            presumptive: _presumptive,
          );
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Form(
          key: _form,
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _w(
                _TaxYearDropdown(
                  value: _taxYear,
                  onChanged: (v) => setState(() => _taxYear = v),
                ),
              ),
              _w(_money(_income, 'Estimated income (blank = from books)')),
              _w(
                DropdownButtonFormField<String>(
                  initialValue: _regime,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Regime'),
                  items: const [
                    DropdownMenuItem(value: 'new', child: Text('New')),
                    DropdownMenuItem(value: 'old', child: Text('Old')),
                  ],
                  onChanged: (v) => setState(() => _regime = v ?? _regime),
                ),
              ),
              _w(
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Presumptive scheme'),
                  value: _presumptive,
                  onChanged: (v) => setState(() => _presumptive = v),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: BusyButton(onPressed: _calc, label: 'Calculate'),
        ),
        if (r != null) ...[
          const SizedBox(height: 16),
          UnverifiedNote(r.unverified),
          StatRow(
            children: [
              StatTile(
                label: 'Estimated income',
                value: formatMoney(r.estimatedIncome),
              ),
              StatTile(label: 'Tax', value: formatMoney(r.tax.total)),
              StatTile(label: 'TDS credit', value: formatMoney(r.tdsCredit)),
              StatTile(label: 'Net tax', value: formatMoney(r.netTax)),
              StatTile(label: 'Paid', value: formatMoney(r.paid)),
              StatTile(label: 'Balance', value: formatMoney(r.balance)),
            ],
          ),
          Text(
            r.required
                ? 'Advance tax is due: net tax is Rs 10,000 or more.'
                : 'No advance tax needed: net tax is below Rs 10,000.',
          ),
          const ReportSectionTitle('Instalments'),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Due date')),
                DataColumn(label: Text('Cumulative %'), numeric: true),
                DataColumn(label: Text('Due'), numeric: true),
                DataColumn(label: Text('Paid by date'), numeric: true),
                DataColumn(label: Text('Shortfall'), numeric: true),
                DataColumn(label: Text('Interest 234C'), numeric: true),
              ],
              rows: [
                for (final i in r.instalments)
                  DataRow(
                    cells: [
                      DataCell(Text(formatDate(i.dueDate))),
                      DataCell(Text('${i.cumulativePct.toStringAsFixed(0)}%')),
                      DataCell(Text(formatAmount(i.cumulativeDue))),
                      DataCell(Text(formatAmount(i.paidByDate))),
                      DataCell(Text(formatAmount(i.shortfall))),
                      DataCell(Text(formatAmount(i.interest425))),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Interest for paying less than 90% (234B): ${formatMoney(r.interest424)}',
          ),
        ],
      ],
    );
  }
}
