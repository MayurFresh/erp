import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/busy.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../compliance/compliance_models.dart' show Tax;
import '../compliance/compliance_widgets.dart';
import '../filings/filing_widgets.dart';
import 'gst_filing_models.dart';
import '../filings/filing_models.dart' show contractFy;
import 'gst_filing_repository.dart';

/// `/gst/gstr9?fy=`: the annual return pack.
class Gstr9Screen extends ConsumerStatefulWidget {
  const Gstr9Screen({super.key, this.fy});

  final String? fy;

  @override
  ConsumerState<Gstr9Screen> createState() => _Gstr9State();
}

class _Gstr9State extends ConsumerState<Gstr9Screen> {
  late String _fy =
      widget.fy ??
      contractFy(DateTime(DateTime.now().year, DateTime.now().month - 3));

  Future<void> _csv() async {
    try {
      final text = await runBlocking(
        context,
        () => ref.read(gstFilingRepositoryProvider).gstr9Csv(_fy),
      );
      if (text != null && mounted) await shareText(context, text, 'CSV');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(gstr9Provider(_fy));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'GSTR-9 annual pack',
          subtitle: 'Figures for the annual return, FY $_fy',
          actions: [
            BusyButton(
              onPressed: _csv,
              label: 'Share CSV',
              icon: Icons.ios_share,
            ),
          ],
        ),
        FilterBar(
          children: [
            FilterDropdown<String>(
              width: 140,
              label: 'Year',
              value: _fy,
              options: {for (final y in recentFys()) y: y},
              onChanged: (v) => setState(() => _fy = v ?? _fy),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<Gstr9Pack>(
            value: value,
            onRetry: () => ref.invalidate(gstr9Provider(_fy)),
            data: (p) => _Pack(pack: p),
          ),
        ),
      ],
    );
  }
}

Tax _asTax(Object? v) =>
    v is num ? Tax(taxable: v.toDouble()) : Tax.fromJson(v);

List<(String, Tax)> _rows(Json table, Map<String, String> labels) => [
  for (final e in labels.entries)
    if (table.containsKey(e.key)) (e.value, _asTax(table[e.key])),
];

class _Pack extends StatelessWidget {
  const _Pack({required this.pack});

  final Gstr9Pack pack;

  @override
  Widget build(BuildContext context) {
    final p = pack;
    final theme = Theme.of(context);
    DataCell n(double v) => DataCell(Text(formatAmount(v)));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('GSTIN ${p.gstin}'),
            Text('Turnover ${formatMoney(p.turnover)}'),
            Pill(
              p.mandatory ? 'GSTR-9 required' : 'GSTR-9 optional',
              color: p.mandatory ? Colors.orange.shade800 : null,
            ),
            if (p.needs9c) const Pill('GSTR-9C needed (CA)'),
            UnverifiedBadge(p.unverified),
          ],
        ),
        const SizedBox(height: 8),
        WarningsBanner(p.warnings),
        SectionCard(
          title: 'Table 4 Outward supplies',
          child: TaxTable(
            firstColumn: '',
            rows: _rows(p.t4, const {
              'b2b': '4B B2B',
              'b2c': '4A B2C',
              'creditNotes': '4I Credit notes',
              'rcm': '4G Reverse charge',
              'net': 'Net',
            }),
          ),
        ),
        SectionCard(
          title: 'Table 5 Exempt and non-GST',
          child: TaxTable(
            firstColumn: '',
            rows: _rows(p.t5, const {
              'nilExempt': '5D Nil, exempt',
              'nonGst': '5F Non-GST',
            }),
          ),
        ),
        SectionCard(
          title: 'Table 6 ITC availed',
          child: TaxTable(
            firstColumn: '',
            rows: _rows(p.t6, const {
              'others': '6B Inputs, services, goods',
              'rcm': '6C Reverse charge',
            }),
          ),
        ),
        SectionCard(
          title: 'Table 7 ITC reversed',
          child: TaxTable(
            firstColumn: '',
            rows: _rows(p.t7, const {
              'rule37': '7B Rule 37',
              'rule42_43': '7C Rules 42 and 43',
            }),
          ),
        ),
        SectionCard(
          title: 'Table 8 ITC per books and 2B',
          child: TaxTable(
            firstColumn: '',
            rows: _rows(p.t8, const {
              'itcIn3b': 'ITC in 3B',
              'itcIn2b': 'ITC in 2B',
              'difference': 'Difference',
            }),
          ),
        ),
        SectionCard(
          title: 'Table 9 Tax paid',
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 40,
              columns: [
                const DataColumn(label: Text('')),
                for (final h in gstHeads)
                  DataColumn(label: Text(headLabel(h)), numeric: true),
              ],
              rows: [
                for (final (l, k) in const [
                  ('Payable', 'payable'),
                  ('Paid through credit', 'paidCredit'),
                  ('Paid in cash', 'paidCash'),
                ])
                  DataRow(
                    cells: [
                      DataCell(Text(l)),
                      for (final h in gstHeads) n(Heads.fromJson(p.t9[k])[h]),
                    ],
                  ),
              ],
            ),
          ),
        ),
        if (p.t10to13.isNotEmpty)
          SectionCard(title: 'Tables 10 to 13', child: Text(p.t10to13)),
        SectionCard(
          title: 'Month by month',
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 40,
              columns: const [
                DataColumn(label: Text('Month')),
                DataColumn(label: Text('GSTR-1 taxable'), numeric: true),
                DataColumn(label: Text('GSTR-1 tax'), numeric: true),
                DataColumn(label: Text('3B taxable'), numeric: true),
                DataColumn(label: Text('3B tax'), numeric: true),
                DataColumn(label: Text('1 filed')),
                DataColumn(label: Text('3B filed')),
              ],
              rows: [
                for (final m in p.monthly)
                  DataRow(
                    cells: [
                      DataCell(Text(periodLabel(m.period))),
                      n(m.gstr1.taxable),
                      n(m.gstr1.tax),
                      n(m.gstr3b.taxable),
                      n(m.gstr3b.tax),
                      DataCell(_filed(m.gstr1Filed)),
                      DataCell(_filed(m.gstr3bFiled)),
                    ],
                  ),
              ],
            ),
          ),
        ),
        _Hsn('Table 17 Outward HSN summary', p.t17),
        _Hsn('Table 18 Inward HSN summary', p.t18),
        Text(
          'Keep the acknowledgement PDF after filing on the portal.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

Widget _filed(bool v) => Icon(
  v ? Icons.check_circle_outline : Icons.cancel_outlined,
  color: v ? Colors.green.shade700 : Colors.red.shade700,
  semanticLabel: v ? 'filed' : 'not filed',
);

class _Hsn extends StatelessWidget {
  const _Hsn(this.title, this.rows);

  final String title;
  final List<HsnRow> rows;

  @override
  Widget build(BuildContext context) => SectionCard(
    title: title,
    child: rows.isEmpty
        ? const Text('None')
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 40,
              columns: const [
                DataColumn(label: Text('HSN')),
                DataColumn(label: Text('Description')),
                DataColumn(label: Text('Taxable'), numeric: true),
                DataColumn(label: Text('IGST'), numeric: true),
                DataColumn(label: Text('CGST'), numeric: true),
                DataColumn(label: Text('SGST'), numeric: true),
              ],
              rows: [
                for (final r in rows)
                  DataRow(
                    cells: [
                      DataCell(Text(r.code)),
                      DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 200),
                          child: Text(
                            r.description,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      DataCell(Text(formatAmount(r.taxable))),
                      DataCell(Text(formatAmount(r.igst))),
                      DataCell(Text(formatAmount(r.cgst))),
                      DataCell(Text(formatAmount(r.sgst))),
                    ],
                  ),
              ],
            ),
          ),
  );
}
