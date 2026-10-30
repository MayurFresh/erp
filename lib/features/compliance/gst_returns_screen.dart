import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../reports/report_widgets.dart'
    show ReportSectionTitle, StatRow, StatTile, tabularFigures;
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';

/// `/gst-returns`: GSTR-1 data and the GSTR-3B form for a month.
class GstReturnsScreen extends ConsumerStatefulWidget {
  const GstReturnsScreen({super.key});

  @override
  ConsumerState<GstReturnsScreen> createState() => _GstReturnsScreenState();
}

class _GstReturnsScreenState extends ConsumerState<GstReturnsScreen> {
  String _period = previousMonth();
  bool _exporting = false;

  Future<void> _exportGstn() async {
    setState(() => _exporting = true);
    try {
      final text = await ref
          .read(complianceRepositoryProvider)
          .gstr1Gstn(_period);
      if (mounted) await shareText(context, text, 'GSTN JSON');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'GST returns',
          subtitle: 'Working data for filing on the GST portal',
          actions: [
            FilledButton.tonalIcon(
              onPressed: _exporting ? null : _exportGstn,
              icon: const Icon(Icons.ios_share),
              label: const Text('Export GSTN JSON'),
            ),
          ],
        ),
        FilterBar(
          children: [
            MonthPicker(
              period: _period,
              onChanged: (p) => setState(() => _period = p),
            ),
          ],
        ),
        const TabBar(
          tabs: [
            Tab(text: 'GSTR-1'),
            Tab(text: 'GSTR-3B'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _Gstr1View(period: _period),
              _Gstr3bView(period: _period),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _body<T>(
  AsyncValue<T> value,
  VoidCallback retry,
  List<Widget> Function(T) build,
) => AsyncValueView<T>(
  value: value,
  onRetry: retry,
  data: (d) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
    children: build(d),
  ),
);

class _Gstr1View extends ConsumerWidget {
  const _Gstr1View({required this.period});

  final String period;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _body<Gstr1>(
    ref.watch(gstr1Provider(period)),
    () => ref.invalidate(gstr1Provider(period)),
    (g) => [
      if (g.hasVariance)
        WarningsBanner(
          [
            'Return totals differ from the output tax ledger: '
                'IGST ${formatAmount(g.variance.igst)}, '
                'CGST ${formatAmount(g.variance.cgst)}, '
                'SGST ${formatAmount(g.variance.sgst)}. '
                'Check for entries posted directly to tax accounts.',
          ],
          title: 'Variance against the ledger',
          error: true,
        ),
      WarningsBanner(g.warnings, title: g.warnings.isEmpty ? null : 'Warnings'),
      StatRow(
        children: [
          StatTile(
            label: 'Taxable value',
            value: formatMoney(g.totals.taxable),
          ),
          StatTile(label: 'IGST', value: formatMoney(g.totals.igst)),
          StatTile(label: 'CGST', value: formatMoney(g.totals.cgst)),
          StatTile(label: 'SGST', value: formatMoney(g.totals.sgst)),
        ],
      ),
      Text(
        'GSTIN ${g.gstin.isEmpty ? '—' : g.gstin} · ${g.filing} filing · '
        'outward supplies net of credit notes',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const ReportSectionTitle('Sections'),
      for (final s in g.sections) _SectionTile(section: s),
      _HsnTile(rows: g.hsn),
      _NilTile(nil: g.nil),
      _DocsTile(docs: g.docs),
      const SizedBox(height: 8),
      TaxTable(
        firstColumn: 'Ledger movement',
        rows: [('Output tax ledger', g.ledger), ('Variance', g.variance)],
        showTaxable: false,
      ),
    ],
  );
}

class _SectionTile extends StatelessWidget {
  const _SectionTile({required this.section});

  final Gstr1Section section;

  @override
  Widget build(BuildContext context) {
    final t = section.total;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        title: Text(section.title),
        subtitle: Text(
          '${section.count} ${section.count == 1 ? 'entry' : 'entries'} · '
          'taxable ${formatMoney(t.taxable)} · tax ${formatMoney(t.tax)}',
        ),
        children: [
          if (section.rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Nothing in this section.'),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Number')),
                  DataColumn(label: Text('Date')),
                  DataColumn(label: Text('Party / GSTIN')),
                  DataColumn(label: Text('Place')),
                  DataColumn(label: Text('Value'), numeric: true),
                  DataColumn(label: Text('Taxable'), numeric: true),
                  DataColumn(label: Text('Tax'), numeric: true),
                ],
                rows: [
                  for (final r in section.rows)
                    DataRow(
                      cells: [
                        DataCell(Text(r.number)),
                        DataCell(
                          Text(r.date.isEmpty ? '' : formatDate(r.date)),
                        ),
                        DataCell(
                          Text(
                            [
                              r.party,
                              r.gstin,
                            ].where((e) => e.isNotEmpty).join(' · '),
                          ),
                        ),
                        DataCell(Text(r.pos)),
                        DataCell(
                          Text(formatAmount(r.value), style: tabularFigures),
                        ),
                        DataCell(
                          Text(
                            formatAmount(r.tax.taxable),
                            style: tabularFigures,
                          ),
                        ),
                        DataCell(
                          Text(formatAmount(r.tax.tax), style: tabularFigures),
                        ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HsnTile extends StatelessWidget {
  const _HsnTile({required this.rows});

  final List<HsnRow> rows;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ExpansionTile(
      shape: const Border(),
      title: const Text('HSN summary'),
      subtitle: Text('${rows.length} ${rows.length == 1 ? 'line' : 'lines'}'),
      children: [
        if (rows.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Segment')),
                DataColumn(label: Text('HSN')),
                DataColumn(label: Text('Description')),
                DataColumn(label: Text('Qty'), numeric: true),
                DataColumn(label: Text('Rate'), numeric: true),
                DataColumn(label: Text('Taxable'), numeric: true),
                DataColumn(label: Text('Tax'), numeric: true),
              ],
              rows: [
                for (final r in rows)
                  DataRow(
                    cells: [
                      DataCell(Text(r.segment.toUpperCase())),
                      DataCell(Text(r.hsnCode)),
                      DataCell(Text(r.description)),
                      DataCell(Text('${formatQty(r.qty)} ${r.unit}')),
                      DataCell(Text(formatPercent(r.rate))),
                      DataCell(Text(formatAmount(r.tax.taxable))),
                      DataCell(Text(formatAmount(r.tax.tax))),
                    ],
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _NilTile extends StatelessWidget {
  const _NilTile({required this.nil});

  final Map<String, double> nil;

  static const _labels = {
    'interRegistered': 'Inter-state, registered',
    'intraRegistered': 'Intra-state, registered',
    'interUnregistered': 'Inter-state, unregistered',
    'intraUnregistered': 'Intra-state, unregistered',
  };

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ExpansionTile(
      shape: const Border(),
      title: const Text('Nil-rated, exempt and non-GST supplies'),
      children: [
        for (final e in _labels.entries)
          ListTile(
            dense: true,
            title: Text(e.value),
            trailing: Text(formatMoney(nil[e.key]), style: tabularFigures),
          ),
      ],
    ),
  );
}

class _DocsTile extends StatelessWidget {
  const _DocsTile({required this.docs});

  final List<DocRange> docs;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ExpansionTile(
      shape: const Border(),
      title: const Text('Documents issued'),
      subtitle: Text(
        '${docs.length} ${docs.length == 1 ? 'series' : 'series'}',
      ),
      children: [
        for (final d in docs)
          ListTile(
            dense: true,
            title: Text(
              '${d.kind == 'credit_note' ? 'Credit notes' : 'Invoices'}: '
              '${d.from} – ${d.to}',
            ),
            subtitle: Text('${d.total} issued, ${d.cancelled} cancelled'),
          ),
      ],
    ),
  );
}

class _Gstr3bView extends ConsumerWidget {
  const _Gstr3bView({required this.period});

  final String period;

  @override
  Widget build(BuildContext context, WidgetRef ref) => _body<Gstr3b>(
    ref.watch(gstr3bProvider(period)),
    () => ref.invalidate(gstr3bProvider(period)),
    (g) => [
      WarningsBanner(g.warnings, title: g.warnings.isEmpty ? null : 'Warnings'),
      SectionCard(
        title: '3.1 Outward and inward supplies liable to tax',
        child: TaxTable(
          firstColumn: 'Nature of supplies',
          rows: [
            ('(a) Outward taxable supplies (net of credit notes)', g.outward),
            (
              '(c) Other outward supplies (nil, exempt)',
              Tax(taxable: g.zeroNil),
            ),
            ('(d) Inward supplies on reverse charge', g.inwardRcm),
          ],
        ),
      ),
      SectionCard(
        title: '3.2 Inter-state supplies to unregistered persons',
        child: g.interState.isEmpty
            ? const Text('None in this period.')
            : TaxTable(
                firstColumn: 'Place of supply',
                rows: [
                  for (final r in g.interState)
                    (r.pos, Tax(taxable: r.taxable, igst: r.igst)),
                ],
              ),
      ),
      SectionCard(
        title: '4. Eligible ITC',
        child: TaxTable(
          firstColumn: 'Details',
          showTaxable: false,
          rows: [
            ('4A(3) Inward supplies on reverse charge', g.itcRcm),
            ('4A(5) All other ITC', g.itcOthers),
            ('4B Reversed', g.itcReversed),
            ('4C Net ITC available', g.itcNet),
          ],
        ),
      ),
      SectionCard(
        title: '6.1 Tax payable',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TaxTable(
              firstColumn: 'Payable',
              showTaxable: false,
              rows: [
                ('Tax payable (outward + RCM − net ITC)', g.payable),
                ('Of which RCM, payable in cash', g.rcmCash),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Payable is floored at zero for each head, with no '
              'cross-utilisation of IGST, CGST and SGST credit.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ],
  );
}
